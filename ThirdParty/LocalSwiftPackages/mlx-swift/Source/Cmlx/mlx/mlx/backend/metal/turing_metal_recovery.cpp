#include "mlx/backend/metal/turing_metal_recovery.h"

#include <Metal/Metal.hpp>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <memory>
#include <stdexcept>

#include "mlx/backend/metal/allocator.h"
#include "mlx/backend/metal/device.h"
#include "mlx/backend/metal/turing_command_buffer_diagnostics.h"
#include "mlx/device.h"

namespace mlx::core::metal::turing {
namespace {

thread_local uint32_t execution_depth = 0;

bool token_equal(
    mlx_turing_metal_recovery_token lhs,
    mlx_turing_metal_recovery_token rhs) noexcept {
  return lhs.high == rhs.high && lhs.low == rhs.low;
}

struct ProbeCompletionState {
  std::mutex mutex;
  std::condition_variable condition;
  bool completed{false};
  int32_t status{0};
  int32_t error_code{0};
  bool readback_matches{false};
  MTL::Buffer* source{nullptr};
  MTL::Buffer* destination{nullptr};
  std::chrono::steady_clock::time_point started;
};

} // namespace

ExecutionLease::ExecutionLease(
    RecoveryController* owner,
    bool outermost) noexcept
    : owner_(owner), outermost_(outermost) {}

ExecutionLease::ExecutionLease(ExecutionLease&& other) noexcept
    : owner_(other.owner_), outermost_(other.outermost_) {
  other.owner_ = nullptr;
  other.outermost_ = false;
}

ExecutionLease& ExecutionLease::operator=(ExecutionLease&& other) noexcept {
  if (this != &other) {
    if (owner_ != nullptr) {
      owner_->release_execution(outermost_);
    }
    owner_ = other.owner_;
    outermost_ = other.outermost_;
    other.owner_ = nullptr;
    other.outermost_ = false;
  }
  return *this;
}

ExecutionLease::~ExecutionLease() {
  if (owner_ != nullptr) {
    owner_->release_execution(outermost_);
  }
}

RecoveryController& RecoveryController::shared() noexcept {
  static RecoveryController value;
  return value;
}

ExecutionLease RecoveryController::acquire_execution(ExecutionKind kind) {
  if (execution_depth > 0) {
    ++execution_depth;
    return ExecutionLease(this, false);
  }
  std::lock_guard<std::mutex> lock(mutex_);
  const bool permitted = state_ == MLX_TURING_METAL_RECOVERY_READY ||
      (state_ == MLX_TURING_METAL_RECOVERY_PROBING &&
       kind == ExecutionKind::probe);
  if (!permitted) {
    throw std::runtime_error(
        state_ == MLX_TURING_METAL_RECOVERY_UNAVAILABLE
            ? "Turing MLX Metal is unavailable until relaunch."
            : "Turing MLX Metal recovery is in progress.");
  }
  execution_depth = 1;
  ++active_execution_count_;
  return ExecutionLease(this, true);
}

void RecoveryController::release_execution(bool outermost) noexcept {
  if (execution_depth > 0) {
    --execution_depth;
  }
  if (!outermost) {
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (active_execution_count_ > 0) {
    --active_execution_count_;
  }
  condition_.notify_all();
}

mlx_turing_metal_recovery_begin_result RecoveryController::begin(
    uint64_t expected_failure_epoch,
    uint64_t expected_generation) {
  std::lock_guard<std::mutex> lock(mutex_);
  mlx_turing_metal_recovery_begin_result result{};
  if (state_ == MLX_TURING_METAL_RECOVERY_UNAVAILABLE) {
    result.result_code = MLX_TURING_METAL_RECOVERY_UNAVAILABLE_RESULT;
  } else if (has_active_owner_ ||
             state_ != MLX_TURING_METAL_RECOVERY_READY) {
    result.result_code = MLX_TURING_METAL_RECOVERY_ALREADY_OWNED;
  } else if (expected_generation != generation_) {
    result.result_code = MLX_TURING_METAL_RECOVERY_STALE_FAILURE;
  } else if (expected_failure_epoch == 0 ||
             expected_failure_epoch != diagnostics().failure_epoch() ||
             !diagnostics().is_poisoned()) {
    result.result_code = MLX_TURING_METAL_RECOVERY_STALE_FAILURE;
  } else {
    active_owner_ = {expected_failure_epoch, next_token_++};
    has_active_owner_ = true;
    state_ = MLX_TURING_METAL_RECOVERY_DRAINING;
    set_reason_locked("draining");
    result.result_code = MLX_TURING_METAL_RECOVERY_OK;
    result.token = active_owner_;
  }
  result.snapshot = snapshot_locked();
  return result;
}

mlx_turing_metal_recovery_snapshot RecoveryController::wait_for_quiescence(
    mlx_turing_metal_recovery_token token,
    std::chrono::nanoseconds timeout) {
  std::unique_lock<std::mutex> lock(mutex_);
  if (!owns_token_locked(token) ||
      state_ != MLX_TURING_METAL_RECOVERY_DRAINING) {
    set_reason_locked("staleRecoveryOwner");
    return snapshot_locked();
  }
  const bool drained = condition_.wait_for(lock, timeout, [this] {
    return active_execution_count_ == 0 && in_flight_count_ == 0;
  });
  set_reason_locked(drained ? "quiescent" : "drainTimedOut");
  return snapshot_locked();
}

mlx_turing_metal_recovery_reset_result RecoveryController::reset_streams(
    mlx_turing_metal_recovery_token token,
    uint64_t baseline_active_bytes,
    uint64_t residual_tolerance_bytes) {
  std::lock_guard<std::mutex> lock(mutex_);
  mlx_turing_metal_recovery_reset_result result{};
  result.old_generation = generation_;
  result.candidate_generation = generation_ + 1;
  if (!owns_token_locked(token)) {
    result.result_code = MLX_TURING_METAL_RECOVERY_STALE_OWNER;
    result.snapshot = snapshot_locked();
    return result;
  }
  if (state_ != MLX_TURING_METAL_RECOVERY_DRAINING) {
    result.result_code = MLX_TURING_METAL_RECOVERY_RESET_FAILED;
    result.snapshot = snapshot_locked();
    return result;
  }
  if (active_execution_count_ != 0) {
    result.result_code = MLX_TURING_METAL_RECOVERY_ACTIVE_EXECUTION;
    result.snapshot = snapshot_locked();
    return result;
  }
  if (in_flight_count_ != 0) {
    result.result_code = MLX_TURING_METAL_RECOVERY_IN_FLIGHT_BUFFERS;
    result.snapshot = snapshot_locked();
    return result;
  }

  state_ = MLX_TURING_METAL_RECOVERY_RESETTING;
  set_reason_locked("resettingStreams");
  result.active_bytes_before = allocator().get_active_memory();
  result.cache_bytes_before = allocator().get_cache_memory();
  try {
    const auto reset = device(mlx::core::Device::gpu)
                           .reset_streams_for_turing_recovery(
                               result.candidate_generation);
    result.disposed_stream_count = reset.disposed_stream_count;
    result.recreated_queue_count = reset.recreated_queue_count;
    stream_reset_count_ += 1;
    queue_recreation_count_ += reset.recreated_queue_count;
    allocator().clear_cache();
    result.active_bytes_after = allocator().get_active_memory();
    result.cache_bytes_after = allocator().get_cache_memory();
  } catch (const std::exception& error) {
    result.result_code = MLX_TURING_METAL_RECOVERY_RESET_FAILED;
    set_reason_locked(error.what());
    result.snapshot = snapshot_locked();
    return result;
  } catch (...) {
    result.result_code = MLX_TURING_METAL_RECOVERY_RESET_FAILED;
    set_reason_locked("unknownStreamResetFailure");
    result.snapshot = snapshot_locked();
    return result;
  }

  const uint64_t maximum_active =
      baseline_active_bytes > UINT64_MAX - residual_tolerance_bytes
      ? UINT64_MAX
      : baseline_active_bytes + residual_tolerance_bytes;
  if (result.active_bytes_after > maximum_active) {
    result.result_code = MLX_TURING_METAL_RECOVERY_RESIDENCY_LEAK;
    set_reason_locked("residualActiveMemoryExceeded");
    result.snapshot = snapshot_locked();
    return result;
  }

  const uint64_t acknowledged = diagnostics().acknowledge_failure_for_recovery();
  // Sibling command buffers from the already-closed generation may complete
  // after the first failure and advance the epoch while the owner drains.
  // No new generation can enter through the execution gate in this state.
  if (acknowledged == 0 || acknowledged < token.high) {
    result.result_code = MLX_TURING_METAL_RECOVERY_STALE_FAILURE;
    set_reason_locked("failureEpochChangedBeforeAcknowledgment");
    result.snapshot = snapshot_locked();
    return result;
  }
  state_ = MLX_TURING_METAL_RECOVERY_PROBING;
  set_reason_locked("probing");
  result.result_code = MLX_TURING_METAL_RECOVERY_OK;
  result.snapshot = snapshot_locked();
  return result;
}

mlx_turing_metal_recovery_probe_result RecoveryController::run_probe(
    mlx_turing_metal_recovery_token token,
    std::chrono::nanoseconds timeout) {
  mlx_turing_metal_recovery_probe_result result{};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    result.candidate_generation = generation_ + 1;
    if (!owns_token_locked(token)) {
      result.result_code = MLX_TURING_METAL_RECOVERY_STALE_OWNER;
      result.snapshot = snapshot_locked();
      return result;
    }
    if (state_ != MLX_TURING_METAL_RECOVERY_PROBING) {
      result.result_code = MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
      result.snapshot = snapshot_locked();
      return result;
    }
  }

  constexpr size_t kProbeBytes = 256;
  auto state = std::make_shared<ProbeCompletionState>();
  state->started = std::chrono::steady_clock::now();
  auto pool = new_scoped_memory_pool();
  try {
    auto& metal_device = device(mlx::core::Device::gpu);
    auto* queue = metal_device.turing_recovery_probe_queue();
    state->source = metal_device.mtl_device()->newBuffer(
        kProbeBytes, MTL::ResourceStorageModeShared);
    state->destination = metal_device.mtl_device()->newBuffer(
        kProbeBytes, MTL::ResourceStorageModeShared);
    if (!state->source || !state->destination) {
      throw std::runtime_error("Unable to allocate recovery probe buffers.");
    }
    auto* source_words = static_cast<uint32_t*>(state->source->contents());
    auto* destination_words =
        static_cast<uint32_t*>(state->destination->contents());
    for (size_t index = 0; index < kProbeBytes / sizeof(uint32_t); ++index) {
      source_words[index] =
          (static_cast<uint32_t>(index) * 0x9E3779B9u) ^ 0xA5A5A5A5u;
      destination_words[index] = 0;
    }

    auto* command_buffer = queue->commandBuffer();
    if (!command_buffer) {
      throw std::runtime_error("Unable to allocate recovery probe command buffer.");
    }
    command_buffer->retain();
    auto diagnostic_state = diagnostics().make_build_state(-1, queue, 0, 0);
    result.command_buffer_id = diagnostic_state->command_buffer_id;
    auto* blit = command_buffer->blitCommandEncoder();
    if (!blit) {
      command_buffer->release();
      throw std::runtime_error("Unable to allocate recovery probe blit encoder.");
    }
    blit->copyFromBuffer(
        state->source, 0, state->destination, 0, kProbeBytes);
    blit->endEncoding();
    diagnostics().prepare_submission(
        diagnostic_state, command_buffer, 1, kProbeBytes * 2);
    command_buffer->addCompletedHandler(
        [state, diagnostic_state, command_buffer](
            MTL::CommandBuffer* completed) noexcept {
          diagnostics().complete_noexcept(diagnostic_state, completed);
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->status = static_cast<int32_t>(completed->status());
            if (const auto* error = completed->error()) {
              state->error_code = static_cast<int32_t>(error->code());
            }
            state->readback_matches = std::memcmp(
                state->source->contents(),
                state->destination->contents(),
                kProbeBytes) == 0;
            state->completed = true;
          }
          state->source->release();
          state->destination->release();
          command_buffer->release();
          state->condition.notify_all();
        });
    command_buffer->commit();
  } catch (const std::exception& error) {
    if (state->source) {
      state->source->release();
    }
    if (state->destination) {
      state->destination->release();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    set_reason_locked(error.what());
    result.result_code = MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
    result.snapshot = snapshot_locked();
    return result;
  }

  {
    std::unique_lock<std::mutex> lock(state->mutex);
    const bool completed = state->condition.wait_for(
        lock, timeout, [&state] { return state->completed; });
    result.elapsed_nanoseconds = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - state->started)
            .count());
    if (!completed) {
      result.result_code = MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
      result.completion_status = 0;
      result.readback_matches = 0;
    } else {
      result.completion_status = state->status;
      result.metal_error_code = state->error_code;
      result.readback_matches = state->readback_matches ? 1 : 0;
      result.result_code =
          state->status == static_cast<int32_t>(MTL::CommandBufferStatusCompleted) &&
              state->error_code == 0 && state->readback_matches
          ? MLX_TURING_METAL_RECOVERY_OK
          : MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
    }
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    last_probe_command_buffer_id_ = result.command_buffer_id;
    last_probe_status_ = result.completion_status;
    if (result.result_code != MLX_TURING_METAL_RECOVERY_OK) {
      set_reason_locked("recoveryProbeFailed");
    }
    result.snapshot = snapshot_locked();
  }
  return result;
}

mlx_turing_metal_recovery_snapshot RecoveryController::finish(
    mlx_turing_metal_recovery_token token,
    const mlx_turing_metal_recovery_probe_result& probe) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!owns_token_locked(token) ||
      state_ != MLX_TURING_METAL_RECOVERY_PROBING ||
      probe.result_code != MLX_TURING_METAL_RECOVERY_OK ||
      in_flight_count_ != 0 || diagnostics().is_poisoned()) {
    set_reason_locked("recoveryFinishRejected");
    return snapshot_locked();
  }
  ++generation_;
  state_ = MLX_TURING_METAL_RECOVERY_READY;
  has_active_owner_ = false;
  active_owner_ = {};
  set_reason_locked("readyForFreshRuntime");
  condition_.notify_all();
  return snapshot_locked();
}

mlx_turing_metal_recovery_snapshot RecoveryController::mark_unavailable(
    mlx_turing_metal_recovery_token token,
    mlx_turing_metal_recovery_result_code code,
    const char* reason) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (has_active_owner_ && !owns_token_locked(token)) {
    set_reason_locked("staleRecoveryOwner");
    return snapshot_locked();
  }
  state_ = MLX_TURING_METAL_RECOVERY_UNAVAILABLE;
  unavailable_code_ = code;
  set_reason_locked(reason ? reason : "unavailableUntilRelaunch");
  has_active_owner_ = false;
  active_owner_ = {};
  condition_.notify_all();
  return snapshot_locked();
}

mlx_turing_metal_recovery_snapshot RecoveryController::snapshot() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return snapshot_locked();
}

void RecoveryController::command_buffer_submitted() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  ++in_flight_count_;
}

void RecoveryController::command_buffer_completed() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  if (in_flight_count_ > 0) {
    --in_flight_count_;
  }
  condition_.notify_all();
}

uint64_t RecoveryController::generation() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return generation_;
}

bool RecoveryController::owns_token_locked(
    mlx_turing_metal_recovery_token token) const noexcept {
  return has_active_owner_ && token_equal(active_owner_, token);
}

mlx_turing_metal_recovery_snapshot RecoveryController::snapshot_locked()
    const noexcept {
  mlx_turing_metal_recovery_snapshot value{};
  value.state = state_;
  value.recovery_generation = generation_;
  value.active_failure_epoch = diagnostics().failure_epoch();
  value.active_execution_count = active_execution_count_;
  value.in_flight_command_buffer_count = in_flight_count_;
  value.stream_reset_count = stream_reset_count_;
  value.queue_recreation_count = queue_recreation_count_;
  value.last_probe_command_buffer_id = last_probe_command_buffer_id_;
  value.last_probe_status = last_probe_status_;
  value.mlx_active_bytes = allocator().get_active_memory();
  value.mlx_cache_bytes = allocator().get_cache_memory();
  value.mlx_peak_bytes = allocator().get_peak_memory();
  std::strncpy(
      value.reason,
      unavailable_reason_,
      MLX_TURING_RECOVERY_REASON_CAPACITY - 1);
  return value;
}

void RecoveryController::set_reason_locked(const char* reason) noexcept {
  std::memset(unavailable_reason_, 0, sizeof(unavailable_reason_));
  if (reason) {
    std::strncpy(
        unavailable_reason_,
        reason,
        sizeof(unavailable_reason_) - 1);
  }
}

#ifdef MLX_TURING_TESTING
void RecoveryController::test_reset() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  state_ = MLX_TURING_METAL_RECOVERY_READY;
  generation_ = 1;
  next_token_ = 1;
  active_owner_ = {};
  has_active_owner_ = false;
  active_execution_count_ = 0;
  in_flight_count_ = 0;
  stream_reset_count_ = 0;
  queue_recreation_count_ = 0;
  last_probe_command_buffer_id_ = 0;
  last_probe_status_ = 0;
  unavailable_code_ = MLX_TURING_METAL_RECOVERY_OK;
  set_reason_locked("ready");
}
#endif

} // namespace mlx::core::metal::turing
