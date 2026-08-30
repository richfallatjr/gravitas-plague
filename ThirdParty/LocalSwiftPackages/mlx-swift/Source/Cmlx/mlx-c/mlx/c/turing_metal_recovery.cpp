#include "mlx/c/turing_metal_recovery.h"

#include <chrono>
#include <cstring>

#include "mlx/backend/metal/turing_metal_recovery.h"

using mlx::core::metal::turing::RecoveryController;

namespace {

template <typename Output>
int require_output(Output* output) {
  if (output != nullptr) {
    std::memset(output, 0, sizeof(Output));
    return 0;
  }
  return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
}

} // namespace

int mlx_turing_metal_recovery_copy_snapshot(
    mlx_turing_metal_recovery_snapshot* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().snapshot();
    return MLX_TURING_METAL_RECOVERY_OK;
  } catch (...) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
}

int mlx_turing_metal_recovery_begin(
    uint64_t expected_failure_epoch,
    uint64_t expected_generation,
    mlx_turing_metal_recovery_begin_result* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().begin(
        expected_failure_epoch, expected_generation);
    return output->result_code;
  } catch (...) {
    output->result_code = MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
    return output->result_code;
  }
}

int mlx_turing_metal_recovery_wait_for_quiescence(
    mlx_turing_metal_recovery_token token,
    uint64_t timeout_nanoseconds,
    mlx_turing_metal_recovery_snapshot* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().wait_for_quiescence(
        token, std::chrono::nanoseconds(timeout_nanoseconds));
    if (output->active_execution_count != 0) {
      return MLX_TURING_METAL_RECOVERY_ACTIVE_EXECUTION;
    }
    if (output->in_flight_command_buffer_count != 0) {
      return MLX_TURING_METAL_RECOVERY_DRAIN_TIMED_OUT;
    }
    return MLX_TURING_METAL_RECOVERY_OK;
  } catch (...) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
}

int mlx_turing_metal_recovery_reset_streams(
    mlx_turing_metal_recovery_token token,
    uint64_t baseline_active_bytes,
    uint64_t residual_active_tolerance_bytes,
    mlx_turing_metal_recovery_reset_result* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().reset_streams(
        token, baseline_active_bytes, residual_active_tolerance_bytes);
    return output->result_code;
  } catch (...) {
    output->result_code = MLX_TURING_METAL_RECOVERY_RESET_FAILED;
    return output->result_code;
  }
}

int mlx_turing_metal_recovery_run_probe(
    mlx_turing_metal_recovery_token token,
    uint64_t timeout_nanoseconds,
    mlx_turing_metal_recovery_probe_result* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().run_probe(
        token, std::chrono::nanoseconds(timeout_nanoseconds));
    return output->result_code;
  } catch (...) {
    output->result_code = MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
    return output->result_code;
  }
}

int mlx_turing_metal_recovery_finish(
    mlx_turing_metal_recovery_token token,
    mlx_turing_metal_recovery_probe_result probe,
    mlx_turing_metal_recovery_snapshot* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().finish(token, probe);
    return output->state == MLX_TURING_METAL_RECOVERY_READY
        ? MLX_TURING_METAL_RECOVERY_OK
        : MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
  } catch (...) {
    return MLX_TURING_METAL_RECOVERY_PROBE_FAILED;
  }
}

int mlx_turing_metal_recovery_mark_unavailable(
    mlx_turing_metal_recovery_token token,
    int32_t result_code,
    const char* reason_utf8,
    mlx_turing_metal_recovery_snapshot* output) {
  if (require_output(output) != 0) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
  try {
    *output = RecoveryController::shared().mark_unavailable(
        token,
        static_cast<mlx_turing_metal_recovery_result_code>(result_code),
        reason_utf8);
    return MLX_TURING_METAL_RECOVERY_UNAVAILABLE_RESULT;
  } catch (...) {
    return MLX_TURING_METAL_RECOVERY_UNSUPPORTED;
  }
}

#ifdef MLX_TURING_TESTING
void mlx_turing_metal_recovery_test_reset(void) {
  RecoveryController::shared().test_reset();
}
#endif
