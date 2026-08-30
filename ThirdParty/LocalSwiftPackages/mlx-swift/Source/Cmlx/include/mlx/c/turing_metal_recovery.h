#ifndef MLX_C_TURING_METAL_RECOVERY_H
#define MLX_C_TURING_METAL_RECOVERY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MLX_TURING_RECOVERY_REASON_CAPACITY 192

typedef enum mlx_turing_metal_recovery_state {
  MLX_TURING_METAL_RECOVERY_READY = 0,
  MLX_TURING_METAL_RECOVERY_DRAINING = 1,
  MLX_TURING_METAL_RECOVERY_RESETTING = 2,
  MLX_TURING_METAL_RECOVERY_PROBING = 3,
  MLX_TURING_METAL_RECOVERY_UNAVAILABLE = 4
} mlx_turing_metal_recovery_state;

typedef enum mlx_turing_metal_recovery_result_code {
  MLX_TURING_METAL_RECOVERY_OK = 0,
  MLX_TURING_METAL_RECOVERY_ALREADY_OWNED = 1,
  MLX_TURING_METAL_RECOVERY_STALE_FAILURE = 2,
  MLX_TURING_METAL_RECOVERY_STALE_OWNER = 3,
  MLX_TURING_METAL_RECOVERY_DRAIN_TIMED_OUT = 4,
  MLX_TURING_METAL_RECOVERY_ACTIVE_EXECUTION = 5,
  MLX_TURING_METAL_RECOVERY_IN_FLIGHT_BUFFERS = 6,
  MLX_TURING_METAL_RECOVERY_RESIDENCY_LEAK = 7,
  MLX_TURING_METAL_RECOVERY_RESET_FAILED = 8,
  MLX_TURING_METAL_RECOVERY_PROBE_FAILED = 9,
  MLX_TURING_METAL_RECOVERY_UNSUPPORTED = 10,
  MLX_TURING_METAL_RECOVERY_UNAVAILABLE_RESULT = 11
} mlx_turing_metal_recovery_result_code;

typedef struct mlx_turing_metal_recovery_token {
  uint64_t high;
  uint64_t low;
} mlx_turing_metal_recovery_token;

typedef struct mlx_turing_metal_recovery_snapshot {
  int32_t state;
  uint64_t recovery_generation;
  uint64_t active_failure_epoch;
  uint64_t active_execution_count;
  uint64_t in_flight_command_buffer_count;
  uint64_t stream_reset_count;
  uint64_t queue_recreation_count;
  uint64_t last_probe_command_buffer_id;
  int32_t last_probe_status;
  uint64_t mlx_active_bytes;
  uint64_t mlx_cache_bytes;
  uint64_t mlx_peak_bytes;
  char reason[MLX_TURING_RECOVERY_REASON_CAPACITY];
} mlx_turing_metal_recovery_snapshot;

typedef struct mlx_turing_metal_recovery_begin_result {
  int32_t result_code;
  mlx_turing_metal_recovery_token token;
  mlx_turing_metal_recovery_snapshot snapshot;
} mlx_turing_metal_recovery_begin_result;

typedef struct mlx_turing_metal_recovery_reset_result {
  int32_t result_code;
  uint64_t old_generation;
  uint64_t candidate_generation;
  uint64_t disposed_stream_count;
  uint64_t recreated_queue_count;
  uint64_t active_bytes_before;
  uint64_t active_bytes_after;
  uint64_t cache_bytes_before;
  uint64_t cache_bytes_after;
  mlx_turing_metal_recovery_snapshot snapshot;
} mlx_turing_metal_recovery_reset_result;

typedef struct mlx_turing_metal_recovery_probe_result {
  int32_t result_code;
  uint64_t candidate_generation;
  uint64_t command_buffer_id;
  int32_t completion_status;
  int32_t metal_error_code;
  uint64_t elapsed_nanoseconds;
  int32_t readback_matches;
  mlx_turing_metal_recovery_snapshot snapshot;
} mlx_turing_metal_recovery_probe_result;

int mlx_turing_metal_recovery_copy_snapshot(
    mlx_turing_metal_recovery_snapshot* output);
int mlx_turing_metal_recovery_begin(
    uint64_t expected_failure_epoch,
    uint64_t expected_generation,
    mlx_turing_metal_recovery_begin_result* output);
int mlx_turing_metal_recovery_wait_for_quiescence(
    mlx_turing_metal_recovery_token token,
    uint64_t timeout_nanoseconds,
    mlx_turing_metal_recovery_snapshot* output);
int mlx_turing_metal_recovery_reset_streams(
    mlx_turing_metal_recovery_token token,
    uint64_t baseline_active_bytes,
    uint64_t residual_active_tolerance_bytes,
    mlx_turing_metal_recovery_reset_result* output);
int mlx_turing_metal_recovery_run_probe(
    mlx_turing_metal_recovery_token token,
    uint64_t timeout_nanoseconds,
    mlx_turing_metal_recovery_probe_result* output);
int mlx_turing_metal_recovery_finish(
    mlx_turing_metal_recovery_token token,
    mlx_turing_metal_recovery_probe_result probe,
    mlx_turing_metal_recovery_snapshot* output);
int mlx_turing_metal_recovery_mark_unavailable(
    mlx_turing_metal_recovery_token token,
    int32_t result_code,
    const char* reason_utf8,
    mlx_turing_metal_recovery_snapshot* output);

/* Implemented only in MLX_TURING_TESTING builds; exported for Swift's Clang
 * importer because target-local C preprocessor defines are not re-exported. */
void mlx_turing_metal_recovery_test_reset(void);

#ifdef __cplusplus
}
#endif

#endif
