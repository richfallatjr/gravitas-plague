#pragma once

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>

#include "mlx/c/turing_metal_recovery.h"

namespace mlx::core::metal::turing {

enum class ExecutionKind : uint8_t { evaluation, synchronization, probe };

class RecoveryController;

class ExecutionLease {
 public:
  ExecutionLease() = default;
  ExecutionLease(RecoveryController* owner, bool outermost) noexcept;
  ExecutionLease(const ExecutionLease&) = delete;
  ExecutionLease& operator=(const ExecutionLease&) = delete;
  ExecutionLease(ExecutionLease&& other) noexcept;
  ExecutionLease& operator=(ExecutionLease&& other) noexcept;
  ~ExecutionLease();

 private:
  RecoveryController* owner_{nullptr};
  bool outermost_{false};
};

class RecoveryController {
 public:
  static RecoveryController& shared() noexcept;

  ExecutionLease acquire_execution(ExecutionKind kind);
  mlx_turing_metal_recovery_begin_result begin(
      uint64_t expected_failure_epoch,
      uint64_t expected_generation);
  mlx_turing_metal_recovery_snapshot wait_for_quiescence(
      mlx_turing_metal_recovery_token token,
      std::chrono::nanoseconds timeout);
  mlx_turing_metal_recovery_reset_result reset_streams(
      mlx_turing_metal_recovery_token token,
      uint64_t baseline_active_bytes,
      uint64_t residual_tolerance_bytes);
  mlx_turing_metal_recovery_probe_result run_probe(
      mlx_turing_metal_recovery_token token,
      std::chrono::nanoseconds timeout);
  mlx_turing_metal_recovery_snapshot finish(
      mlx_turing_metal_recovery_token token,
      const mlx_turing_metal_recovery_probe_result& probe);
  mlx_turing_metal_recovery_snapshot mark_unavailable(
      mlx_turing_metal_recovery_token token,
      mlx_turing_metal_recovery_result_code code,
      const char* reason);
  mlx_turing_metal_recovery_snapshot snapshot() const noexcept;

  void command_buffer_submitted() noexcept;
  void command_buffer_completed() noexcept;
  void release_execution(bool outermost) noexcept;
  uint64_t generation() const noexcept;

#ifdef MLX_TURING_TESTING
  void test_reset() noexcept;
#endif

 private:
  RecoveryController() = default;
  bool owns_token_locked(mlx_turing_metal_recovery_token token) const noexcept;
  mlx_turing_metal_recovery_snapshot snapshot_locked() const noexcept;
  void set_reason_locked(const char* reason) noexcept;

  mutable std::mutex mutex_;
  std::condition_variable condition_;
  mlx_turing_metal_recovery_state state_{MLX_TURING_METAL_RECOVERY_READY};
  uint64_t generation_{1};
  uint64_t next_token_{1};
  mlx_turing_metal_recovery_token active_owner_{};
  bool has_active_owner_{false};
  uint64_t active_execution_count_{0};
  uint64_t in_flight_count_{0};
  uint64_t stream_reset_count_{0};
  uint64_t queue_recreation_count_{0};
  uint64_t last_probe_command_buffer_id_{0};
  int32_t last_probe_status_{0};
  mlx_turing_metal_recovery_result_code unavailable_code_{
      MLX_TURING_METAL_RECOVERY_OK};
  char unavailable_reason_[MLX_TURING_RECOVERY_REASON_CAPACITY]{};
};

} // namespace mlx::core::metal::turing
