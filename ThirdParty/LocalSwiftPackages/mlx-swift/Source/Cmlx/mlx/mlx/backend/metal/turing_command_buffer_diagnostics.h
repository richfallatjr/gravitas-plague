#pragma once

#include <Metal/Metal.hpp>
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>

#include "mlx/c/turing_metal_diagnostics.h"

namespace mlx::core::metal::turing {

constexpr uint64_t kFNVOffsetBasis = 14695981039346656037ULL;
constexpr uint64_t kFNVPrime = 1099511628211ULL;
constexpr size_t kCommandBufferRingCapacity = 64;

struct CommandBufferBuildState {
  uint64_t command_buffer_id{0};
  int32_t stream_index{0};
  uintptr_t command_queue_identity{0};
  mlx_turing_metal_context first_context{};
  mlx_turing_metal_context last_context{};
  bool has_context{false};
  bool mixed_context{false};
  uint32_t primitive_count{0};
  uint64_t primitive_name_hash{kFNVOffsetBasis};
  char first_primitive[MLX_TURING_PRIMITIVE_NAME_CAPACITY]{};
  char last_primitive[MLX_TURING_PRIMITIVE_NAME_CAPACITY]{};
  std::atomic<bool> completion_recorded{false};
  mlx_turing_command_buffer_record submitted_record{};
};

const mlx_turing_metal_context& current_context() noexcept;
void set_context(const mlx_turing_metal_context& context) noexcept;
void clear_context() noexcept;
uint64_t fnv1a_append(uint64_t hash, const char* bytes) noexcept;

class CommandBufferDiagnostics {
 public:
  static CommandBufferDiagnostics& shared() noexcept;

  std::shared_ptr<CommandBufferBuildState> make_build_state(
      int32_t stream_index,
      MTL::CommandQueue* queue,
      int32_t configured_max_ops,
      int32_t configured_max_mb);

  void record_primitive(
      const std::shared_ptr<CommandBufferBuildState>& state,
      const char* primitive_name) noexcept;

  void prepare_submission(
      const std::shared_ptr<CommandBufferBuildState>& state,
      MTL::CommandBuffer* command_buffer,
      uint32_t encoded_operation_count,
      uint64_t referenced_input_bytes_estimate) noexcept;

  void complete_noexcept(
      const std::shared_ptr<CommandBufferBuildState>& state,
      MTL::CommandBuffer* command_buffer) noexcept;

  void mark_device_initializing() noexcept;
  void publish_configuration(
      const char* architecture,
      int32_t architecture_generation,
      int32_t max_ops,
      int32_t max_mb) noexcept;
  bool copy_configuration(mlx_turing_metal_configuration& output) const noexcept;
  bool device_is_initialized() const noexcept;
  uint64_t failure_epoch() const noexcept;
  bool is_poisoned() const noexcept;
  bool copy_last_failure(mlx_turing_command_buffer_record& output) const noexcept;
  size_t copy_recent_records(
      mlx_turing_command_buffer_record* output,
      size_t output_capacity) const noexcept;
  void copy_aggregate(mlx_turing_command_buffer_aggregate& output) const noexcept;
  bool set_failure_path(const char* utf8_path) noexcept;
  void set_external_in_flight_counts(
      uint32_t app_metal_count,
      uint32_t mind_eye_compositor_count) noexcept;
  void copy_external_in_flight_counts(
      uint32_t& app_metal_count,
      uint32_t& mind_eye_compositor_count) const noexcept;

#ifdef MLX_TURING_TESTING
  void test_reset() noexcept;
  void test_inject_failure_on_next_completion(int32_t error_code) noexcept;
  void test_record_synthetic_completion() noexcept;
#endif

 private:
  CommandBufferDiagnostics() = default;

  void append_record_noexcept(mlx_turing_command_buffer_record record) noexcept;
  void publish_failure_noexcept(mlx_turing_command_buffer_record record) noexcept;
  void persist_failure_noexcept(
      const mlx_turing_command_buffer_record& record) noexcept;
  void publish_minimal_internal_failure_noexcept(uint64_t buffer_id) noexcept;

  std::atomic<uint64_t> next_buffer_id_{1};
  std::atomic<uint64_t> next_sequence_{1};
  std::atomic<uint64_t> failure_epoch_{0};
  std::atomic<uint32_t> in_flight_count_{0};
  std::atomic<bool> poisoned_{false};
  std::atomic<bool> device_initialized_{false};
  std::atomic<uint32_t> app_metal_in_flight_count_{0};
  std::atomic<uint32_t> mind_eye_in_flight_count_{0};
#ifdef MLX_TURING_TESTING
  std::atomic<int32_t> injected_failure_code_{0};
#endif

  mutable std::mutex ring_mutex_;
  std::array<mlx_turing_command_buffer_record, kCommandBufferRingCapacity> ring_{};
  size_t ring_count_{0};
  size_t ring_next_index_{0};
  mlx_turing_command_buffer_aggregate aggregate_{};

  mutable std::mutex failure_mutex_;
  mlx_turing_command_buffer_record last_failure_{};
  bool has_failure_{false};

  mutable std::mutex configuration_mutex_;
  mlx_turing_metal_configuration configuration_{};

  mutable std::mutex path_mutex_;
  std::array<char, 1024> failure_path_{};
};

inline CommandBufferDiagnostics& diagnostics() noexcept {
  return CommandBufferDiagnostics::shared();
}

} // namespace mlx::core::metal::turing
