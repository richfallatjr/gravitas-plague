#include "mlx/backend/metal/turing_command_buffer_diagnostics.h"
#include "mlx/backend/metal/turing_metal_recovery.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <string>
#include <TargetConditionals.h>
#include <unistd.h>

#include "mlx/backend/metal/allocator.h"
#include "mlx/backend/metal/turing_metal_failure.h"

namespace mlx::core::metal::turing {
namespace {

thread_local mlx_turing_metal_context thread_context{};
thread_local std::array<mlx_turing_metal_context, 8> thread_context_stack{};
thread_local size_t thread_context_depth{0};

uint64_t uptime_nanoseconds() noexcept {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

template <size_t N>
void copy_utf8(char (&destination)[N], const char* source) noexcept {
  if (!source) {
    destination[0] = '\0';
    return;
  }
  const size_t length = std::min(N - 1, std::strlen(source));
  std::memcpy(destination, source, length);
  destination[length] = '\0';
}

template <size_t N>
void copy_json_safe(char (&destination)[N], const char* source) noexcept {
  if (!source) {
    destination[0] = '\0';
    return;
  }
  size_t output = 0;
  for (size_t input = 0; source[input] && output + 1 < N; ++input) {
    const unsigned char value = static_cast<unsigned char>(source[input]);
    destination[output++] =
        (value < 0x20 || value == '"' || value == '\\') ? '_' : source[input];
  }
  destination[output] = '\0';
}

uint64_t process_phys_footprint_bytes() noexcept {
  task_vm_info_data_t information{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  const auto result = task_info(
      mach_task_self(),
      TASK_VM_INFO,
      reinterpret_cast<task_info_t>(&information),
      &count);
  return result == KERN_SUCCESS ? information.phys_footprint : 0;
}

uint64_t process_available_memory_bytes() noexcept {
#if TARGET_OS_OSX
  // os_proc_available_memory is unavailable to macOS host builds. The app's
  // production target is visionOS, where this field is populated.
  return 0;
#else
  return static_cast<uint64_t>(os_proc_available_memory());
#endif
}

void capture_memory(
    uint64_t& footprint,
    uint64_t& available,
    uint64_t& active,
    uint64_t& cache,
    uint64_t& peak) noexcept {
  footprint = process_phys_footprint_bytes();
  available = process_available_memory_bytes();
  try {
    auto& metal_allocator = allocator();
    active = metal_allocator.get_active_memory();
    cache = metal_allocator.get_cache_memory();
    peak = metal_allocator.get_peak_memory();
  } catch (...) {
    active = 0;
    cache = 0;
    peak = 0;
  }
}

bool contexts_equal(
    const mlx_turing_metal_context& lhs,
    const mlx_turing_metal_context& rhs) noexcept {
  return std::memcmp(&lhs, &rhs, sizeof(lhs)) == 0;
}

void update_maximum(uint64_t& value, uint64_t candidate) noexcept {
  value = std::max(value, candidate);
}

void update_maximum(double& value, double candidate) noexcept {
  value = std::max(value, candidate);
}

void add_duration_bucket(
    mlx_turing_command_buffer_aggregate& aggregate,
    double seconds) noexcept {
  const double milliseconds = seconds * 1000.0;
  if (milliseconds < 5.0) {
    ++aggregate.duration_bucket_lt_5ms;
  } else if (milliseconds < 10.0) {
    ++aggregate.duration_bucket_5_10ms;
  } else if (milliseconds < 20.0) {
    ++aggregate.duration_bucket_10_20ms;
  } else if (milliseconds < 30.0) {
    ++aggregate.duration_bucket_20_30ms;
  } else if (milliseconds < 40.0) {
    ++aggregate.duration_bucket_30_40ms;
  } else if (milliseconds < 50.0) {
    ++aggregate.duration_bucket_40_50ms;
  } else if (milliseconds < 75.0) {
    ++aggregate.duration_bucket_50_75ms;
  } else if (milliseconds < 100.0) {
    ++aggregate.duration_bucket_75_100ms;
  } else if (milliseconds < 150.0) {
    ++aggregate.duration_bucket_100_150ms;
  } else {
    ++aggregate.duration_bucket_gte_150ms;
  }
}

} // namespace

const mlx_turing_metal_context& current_context() noexcept {
  return thread_context;
}

void set_context(const mlx_turing_metal_context& context) noexcept {
  if (thread_context_depth < thread_context_stack.size()) {
    thread_context_stack[thread_context_depth++] = thread_context;
  }
  thread_context = context;
}

void clear_context() noexcept {
  if (thread_context_depth > 0) {
    thread_context = thread_context_stack[--thread_context_depth];
    return;
  }
  thread_context = {};
}

uint64_t fnv1a_append(uint64_t hash, const char* bytes) noexcept {
  if (!bytes) {
    return hash;
  }
  for (const unsigned char* cursor =
           reinterpret_cast<const unsigned char*>(bytes);
       *cursor;
       ++cursor) {
    hash ^= static_cast<uint64_t>(*cursor);
    hash *= kFNVPrime;
  }
  return hash;
}

CommandBufferDiagnostics& CommandBufferDiagnostics::shared() noexcept {
  static CommandBufferDiagnostics value;
  return value;
}

std::shared_ptr<CommandBufferBuildState>
CommandBufferDiagnostics::make_build_state(
    int32_t stream_index,
    MTL::CommandQueue* queue,
    int32_t configured_max_ops,
    int32_t configured_max_mb) {
  auto state = std::make_shared<CommandBufferBuildState>();
  state->command_buffer_id =
      next_buffer_id_.fetch_add(1, std::memory_order_relaxed);
  state->stream_index = stream_index;
  state->command_queue_identity = reinterpret_cast<uintptr_t>(queue);
  state->submitted_record.command_buffer_id = state->command_buffer_id;
  state->submitted_record.stream_index = stream_index;
  state->submitted_record.command_queue_identity = state->command_queue_identity;
  state->submitted_record.configured_max_ops = configured_max_ops;
  state->submitted_record.configured_max_mb = configured_max_mb;
  return state;
}

void CommandBufferDiagnostics::record_primitive(
    const std::shared_ptr<CommandBufferBuildState>& state,
    const char* primitive_name) noexcept {
  if (!state) {
    return;
  }
  const auto& context = current_context();
  if (!state->has_context) {
    state->first_context = context;
    state->last_context = context;
    state->has_context = true;
  } else {
    state->mixed_context |= !contexts_equal(state->last_context, context);
    state->last_context = context;
  }
  if (state->primitive_count == 0) {
    copy_utf8(state->first_primitive, primitive_name);
  }
  copy_utf8(state->last_primitive, primitive_name);
  ++state->primitive_count;
  state->primitive_name_hash =
      fnv1a_append(state->primitive_name_hash, primitive_name);
}

void CommandBufferDiagnostics::prepare_submission(
    const std::shared_ptr<CommandBufferBuildState>& state,
    MTL::CommandBuffer* command_buffer,
    uint32_t encoded_operation_count,
    uint64_t referenced_input_bytes_estimate) noexcept {
  if (!state) {
    return;
  }
  auto& record = state->submitted_record;
  record.encoded_operation_count = encoded_operation_count;
  record.referenced_input_bytes_estimate = referenced_input_bytes_estimate;
  record.primitive_count = state->primitive_count;
  record.primitive_name_hash = state->primitive_name_hash;
  copy_utf8(record.first_primitive, state->first_primitive);
  copy_utf8(record.last_primitive, state->last_primitive);
  record.first_context = state->first_context;
  record.last_context = state->last_context;
  record.mixed_context = state->mixed_context ? 1 : 0;
  if (command_buffer && command_buffer->label()) {
    copy_json_safe(
        record.command_buffer_label,
        command_buffer->label()->utf8String());
  }
  record.submit_uptime_nanoseconds = uptime_nanoseconds();
  record.mlx_buffers_in_flight_at_submit =
      in_flight_count_.fetch_add(1, std::memory_order_acq_rel) + 1;
  RecoveryController::shared().command_buffer_submitted();
  const auto context_app_count = state->last_context.app_metal_in_flight_count;
  const auto context_mind_eye_count =
      state->last_context.mind_eye_compositor_in_flight_count;
  record.app_metal_in_flight_at_submit = context_app_count > 0
      ? context_app_count
      : app_metal_in_flight_count_.load(std::memory_order_acquire);
  record.mind_eye_in_flight_at_submit = context_mind_eye_count > 0
      ? context_mind_eye_count
      : mind_eye_in_flight_count_.load(std::memory_order_acquire);
  capture_memory(
      record.process_phys_footprint_bytes_at_submit,
      record.process_available_memory_bytes_at_submit,
      record.mlx_active_bytes_at_submit,
      record.mlx_cache_bytes_at_submit,
      record.mlx_peak_bytes_at_submit);
  std::lock_guard lock(ring_mutex_);
  ++aggregate_.submitted_count;
}

void CommandBufferDiagnostics::complete_noexcept(
    const std::shared_ptr<CommandBufferBuildState>& state,
    MTL::CommandBuffer* command_buffer) noexcept {
  if (!state) {
    return;
  }
  bool expected = false;
  if (!state->completion_recorded.compare_exchange_strong(expected, true)) {
    return;
  }

  try {
    auto record = state->submitted_record;
    record.completion_uptime_nanoseconds = uptime_nanoseconds();
    if (command_buffer) {
      record.completion_status = static_cast<int32_t>(command_buffer->status());
      record.gpu_start_seconds = command_buffer->GPUStartTime();
      record.gpu_end_seconds = command_buffer->GPUEndTime();
      record.gpu_duration_seconds =
          record.gpu_end_seconds >= record.gpu_start_seconds
          ? record.gpu_end_seconds - record.gpu_start_seconds
          : 0.0;
      record.kernel_start_seconds = command_buffer->kernelStartTime();
      record.kernel_end_seconds = command_buffer->kernelEndTime();
      record.kernel_duration_seconds =
          record.kernel_end_seconds >= record.kernel_start_seconds
          ? record.kernel_end_seconds - record.kernel_start_seconds
          : 0.0;

      if (const auto* error = command_buffer->error()) {
        record.error_code = static_cast<int32_t>(error->code());
        if (error->domain()) {
          copy_json_safe(record.error_domain, error->domain()->utf8String());
        }
        if (error->localizedDescription()) {
          copy_json_safe(
              record.error_description,
              error->localizedDescription()->utf8String());
        }
      }
      record.is_failure =
          command_buffer->status() == MTL::CommandBufferStatusError ? 1 : 0;
    }

#ifdef MLX_TURING_TESTING
    const auto injected = injected_failure_code_.exchange(0);
    if (injected != 0) {
      record.completion_status =
          static_cast<int32_t>(MTL::CommandBufferStatusError);
      record.error_code = injected;
      copy_utf8(record.error_domain, "TuringSyntheticMetalFailure");
      copy_utf8(record.error_description, "Synthetic test completion failure");
      record.is_failure = 1;
      record.is_synthetic_test_failure = 1;
    }
#endif

    capture_memory(
        record.process_phys_footprint_bytes_at_completion,
        record.process_available_memory_bytes_at_completion,
        record.mlx_active_bytes_at_completion,
        record.mlx_cache_bytes_at_completion,
        record.mlx_peak_bytes_at_completion);

    if (record.is_failure) {
      publish_failure_noexcept(record);
    } else {
      append_record_noexcept(record);
    }
  } catch (...) {
    publish_minimal_internal_failure_noexcept(state->command_buffer_id);
  }
  in_flight_count_.fetch_sub(1, std::memory_order_acq_rel);
  RecoveryController::shared().command_buffer_completed();
}

void CommandBufferDiagnostics::append_record_noexcept(
    mlx_turing_command_buffer_record record) noexcept {
  try {
    record.sequence = next_sequence_.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard lock(ring_mutex_);
    ring_[ring_next_index_] = record;
    ring_next_index_ = (ring_next_index_ + 1) % kCommandBufferRingCapacity;
    ring_count_ = std::min(ring_count_ + 1, kCommandBufferRingCapacity);
    ++aggregate_.completed_count;
    aggregate_.failed_count += record.is_failure ? 1 : 0;
    update_maximum(
        aggregate_.maximum_encoded_operation_count,
        static_cast<uint64_t>(record.encoded_operation_count));
    update_maximum(
        aggregate_.maximum_referenced_input_bytes_estimate,
        record.referenced_input_bytes_estimate);
    update_maximum(
        aggregate_.maximum_gpu_duration_seconds,
        record.gpu_duration_seconds);
    update_maximum(
        aggregate_.maximum_kernel_duration_seconds,
        record.kernel_duration_seconds);
    add_duration_bucket(aggregate_, record.gpu_duration_seconds);
  } catch (...) {
  }
}

void CommandBufferDiagnostics::publish_failure_noexcept(
    mlx_turing_command_buffer_record record) noexcept {
  try {
    record.failure_epoch =
        failure_epoch_.fetch_add(1, std::memory_order_acq_rel) + 1;
    {
      std::lock_guard lock(failure_mutex_);
      last_failure_ = record;
      has_failure_ = true;
      poisoned_.store(true, std::memory_order_release);
    }
    persist_failure_noexcept(record);
    append_record_noexcept(record);
  } catch (...) {
    poisoned_.store(true, std::memory_order_release);
  }
}

void CommandBufferDiagnostics::persist_failure_noexcept(
    const mlx_turing_command_buffer_record& record) noexcept {
  try {
    std::array<char, 1024> path{};
    {
      std::lock_guard lock(path_mutex_);
      path = failure_path_;
    }
    if (path[0] == '\0') {
      return;
    }
    std::array<char, 1100> temporary_path{};
    const int temp_length = std::snprintf(
        temporary_path.data(),
        temporary_path.size(),
        "%s.tmp",
        path.data());
    if (temp_length <= 0 ||
        static_cast<size_t>(temp_length) >= temporary_path.size()) {
      return;
    }

    std::array<char, 4096> json{};
    const int json_length = std::snprintf(
        json.data(),
        json.size(),
        "{\"schemaVersion\":1,\"failureEpoch\":%llu,"
        "\"commandBufferID\":%llu,\"streamIndex\":%d,\"status\":%d,"
        "\"errorDomain\":\"%s\",\"errorCode\":%d,"
        "\"errorDescription\":\"%s\",\"gpuDurationSeconds\":%.9f,"
        "\"kernelDurationSeconds\":%.9f,\"configuredMaxOps\":%d,"
        "\"configuredMaxMB\":%d,\"encodedOperationCount\":%u,"
        "\"referencedInputBytesEstimate\":%llu,\"primitiveCount\":%u,"
        "\"primitiveHash\":\"%016llx\",\"firstPrimitive\":\"%s\","
        "\"lastPrimitive\":\"%s\",\"context\":{\"runID\":\"%s\","
        "\"instanceID\":\"%s\",\"segmentIndex\":%d,\"phase\":\"%s\","
        "\"stage\":\"%s\",\"rowStartInclusive\":%d,"
        "\"rowEndExclusive\":%d}}\n",
        static_cast<unsigned long long>(record.failure_epoch),
        static_cast<unsigned long long>(record.command_buffer_id),
        record.stream_index,
        record.completion_status,
        record.error_domain,
        record.error_code,
        record.error_description,
        record.gpu_duration_seconds,
        record.kernel_duration_seconds,
        record.configured_max_ops,
        record.configured_max_mb,
        record.encoded_operation_count,
        static_cast<unsigned long long>(record.referenced_input_bytes_estimate),
        record.primitive_count,
        static_cast<unsigned long long>(record.primitive_name_hash),
        record.first_primitive,
        record.last_primitive,
        record.last_context.run_id,
        record.last_context.instance_id,
        record.last_context.segment_index,
        record.last_context.phase,
        record.last_context.stage,
        record.last_context.row_start_inclusive,
        record.last_context.row_end_exclusive);
    if (json_length <= 0 || static_cast<size_t>(json_length) >= json.size()) {
      return;
    }

    const int descriptor = open(
        temporary_path.data(),
        O_WRONLY | O_CREAT | O_TRUNC,
        S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
      return;
    }
    const ssize_t written = write(descriptor, json.data(), json_length);
    if (written == json_length) {
      fsync(descriptor);
    }
    close(descriptor);
    if (written == json_length) {
      rename(temporary_path.data(), path.data());
    }
  } catch (...) {
  }
}

void CommandBufferDiagnostics::publish_minimal_internal_failure_noexcept(
    uint64_t buffer_id) noexcept {
  mlx_turing_command_buffer_record record{};
  record.command_buffer_id = buffer_id;
  record.is_failure = 1;
  record.completion_status = -1;
  copy_utf8(record.error_domain, "TuringDiagnosticsInternalFailure");
  copy_utf8(
      record.error_description,
      "Command-buffer completion diagnostics failed internally");
  publish_failure_noexcept(record);
}

void CommandBufferDiagnostics::mark_device_initializing() noexcept {
  device_initialized_.store(true, std::memory_order_release);
  std::lock_guard lock(configuration_mutex_);
  configuration_.device_initialized = 1;
}

void CommandBufferDiagnostics::publish_configuration(
    const char* architecture,
    int32_t architecture_generation,
    int32_t max_ops,
    int32_t max_mb) noexcept {
  std::lock_guard lock(configuration_mutex_);
  configuration_.device_initialized = 1;
  copy_utf8(configuration_.architecture, architecture);
  configuration_.architecture_generation = architecture_generation;
  configuration_.resolved_max_ops_per_buffer = max_ops;
  configuration_.resolved_max_mb_per_buffer = max_mb;
}

bool CommandBufferDiagnostics::copy_configuration(
    mlx_turing_metal_configuration& output) const noexcept {
  std::lock_guard lock(configuration_mutex_);
  output = configuration_;
  return configuration_.device_initialized != 0;
}

bool CommandBufferDiagnostics::device_is_initialized() const noexcept {
  return device_initialized_.load(std::memory_order_acquire);
}

uint64_t CommandBufferDiagnostics::failure_epoch() const noexcept {
  return failure_epoch_.load(std::memory_order_acquire);
}

bool CommandBufferDiagnostics::is_poisoned() const noexcept {
  return poisoned_.load(std::memory_order_acquire);
}

uint64_t CommandBufferDiagnostics::acknowledge_failure_for_recovery() noexcept {
  std::lock_guard lock(failure_mutex_);
  if (!has_failure_) {
    return 0;
  }
  const uint64_t acknowledged_epoch = last_failure_.failure_epoch;
  // Keep the record bytes, monotonic failure epoch, bounded ring, aggregate,
  // and persisted JSON intact for postmortem analysis. Only remove the active
  // throw latch after the failed residency pool has been fully unloaded so a
  // genuinely fresh pool can submit work in the same process.
  has_failure_ = false;
  poisoned_.store(false, std::memory_order_release);
  return acknowledged_epoch;
}

bool CommandBufferDiagnostics::copy_last_failure(
    mlx_turing_command_buffer_record& output) const noexcept {
  std::lock_guard lock(failure_mutex_);
  if (!has_failure_) {
    return false;
  }
  output = last_failure_;
  return true;
}

size_t CommandBufferDiagnostics::copy_recent_records(
    mlx_turing_command_buffer_record* output,
    size_t output_capacity) const noexcept {
  if (!output || output_capacity == 0) {
    return 0;
  }
  std::lock_guard lock(ring_mutex_);
  const size_t copied = std::min(output_capacity, ring_count_);
  const size_t oldest =
      ring_count_ == kCommandBufferRingCapacity ? ring_next_index_ : 0;
  const size_t skipped = ring_count_ - copied;
  for (size_t index = 0; index < copied; ++index) {
    output[index] = ring_[(oldest + skipped + index) % kCommandBufferRingCapacity];
  }
  return copied;
}

void CommandBufferDiagnostics::copy_aggregate(
    mlx_turing_command_buffer_aggregate& output) const noexcept {
  std::lock_guard lock(ring_mutex_);
  output = aggregate_;
}

bool CommandBufferDiagnostics::set_failure_path(const char* utf8_path) noexcept {
  if (!utf8_path) {
    return false;
  }
  const size_t length = std::strlen(utf8_path);
  if (length == 0 || length >= failure_path_.size()) {
    return false;
  }
  std::lock_guard lock(path_mutex_);
  std::memcpy(failure_path_.data(), utf8_path, length);
  failure_path_[length] = '\0';
  return true;
}

void CommandBufferDiagnostics::set_external_in_flight_counts(
    uint32_t app_metal_count,
    uint32_t mind_eye_compositor_count) noexcept {
  app_metal_in_flight_count_.store(app_metal_count, std::memory_order_release);
  mind_eye_in_flight_count_.store(
      mind_eye_compositor_count,
      std::memory_order_release);
}

void CommandBufferDiagnostics::copy_external_in_flight_counts(
    uint32_t& app_metal_count,
    uint32_t& mind_eye_compositor_count) const noexcept {
  app_metal_count = app_metal_in_flight_count_.load(std::memory_order_acquire);
  mind_eye_compositor_count =
      mind_eye_in_flight_count_.load(std::memory_order_acquire);
}

#ifdef MLX_TURING_TESTING
void CommandBufferDiagnostics::test_reset() noexcept {
  next_buffer_id_.store(1);
  next_sequence_.store(1);
  failure_epoch_.store(0);
  in_flight_count_.store(0);
  poisoned_.store(false);
  app_metal_in_flight_count_.store(0);
  mind_eye_in_flight_count_.store(0);
  injected_failure_code_.store(0);
  {
    std::lock_guard lock(ring_mutex_);
    ring_ = {};
    ring_count_ = 0;
    ring_next_index_ = 0;
    aggregate_ = {};
  }
  {
    std::lock_guard lock(failure_mutex_);
    last_failure_ = {};
    has_failure_ = false;
  }
}

void CommandBufferDiagnostics::test_inject_failure_on_next_completion(
    int32_t error_code) noexcept {
  injected_failure_code_.store(error_code == 0 ? 1 : error_code);
}

void CommandBufferDiagnostics::test_record_synthetic_completion() noexcept {
  try {
    auto state = make_build_state(0, nullptr, 0, 0);
    record_primitive(state, "TuringSyntheticPrimitive");
    prepare_submission(state, nullptr, 1, 0);
    complete_noexcept(state, nullptr);
  } catch (...) {
  }
}
#endif

TuringMetalCommandBufferFailure::TuringMetalCommandBufferFailure(
    const mlx_turing_command_buffer_record& record)
    : std::runtime_error([&record]() {
        char message[1536]{};
        std::snprintf(
            message,
            sizeof(message),
            "[TURING_MLX_METAL_FAILURE] epoch=%llu buffer=%llu status=%d "
            "domain=%s code=%d gpuSeconds=%.9f stream=%d run=%s instance=%s "
            "segment=%d phase=%s stage=%s operations=%u bytes=%llu first=%s "
            "last=%s",
            static_cast<unsigned long long>(record.failure_epoch),
            static_cast<unsigned long long>(record.command_buffer_id),
            record.completion_status,
            record.error_domain,
            record.error_code,
            record.gpu_duration_seconds,
            record.stream_index,
            record.last_context.run_id,
            record.last_context.instance_id,
            record.last_context.segment_index,
            record.last_context.phase,
            record.last_context.stage,
            record.encoded_operation_count,
            static_cast<unsigned long long>(record.referenced_input_bytes_estimate),
            record.first_primitive,
            record.last_primitive);
        return std::string(message);
      }()),
      failure_epoch_(record.failure_epoch) {}

void throw_if_turing_metal_failed() {
  mlx_turing_command_buffer_record record{};
  if (!diagnostics().copy_last_failure(record)) {
    return;
  }
  throw TuringMetalCommandBufferFailure(record);
}

} // namespace mlx::core::metal::turing
