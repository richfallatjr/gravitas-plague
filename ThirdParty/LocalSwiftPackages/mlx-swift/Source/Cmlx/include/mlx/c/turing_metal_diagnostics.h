#ifndef MLX_C_TURING_METAL_DIAGNOSTICS_H
#define MLX_C_TURING_METAL_DIAGNOSTICS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MLX_TURING_CONTEXT_RUN_ID_CAPACITY 96
#define MLX_TURING_CONTEXT_INSTANCE_ID_CAPACITY 32
#define MLX_TURING_CONTEXT_PHASE_CAPACITY 96
#define MLX_TURING_CONTEXT_STAGE_CAPACITY 128
#define MLX_TURING_CONTEXT_RESIDENCY_ID_CAPACITY 40
#define MLX_TURING_PRIMITIVE_NAME_CAPACITY 96
#define MLX_TURING_ERROR_DOMAIN_CAPACITY 96
#define MLX_TURING_ERROR_DESCRIPTION_CAPACITY 384
#define MLX_TURING_COMMAND_BUFFER_LABEL_CAPACITY 192
#define MLX_TURING_ARCHITECTURE_CAPACITY 64

typedef enum mlx_turing_metal_phase {
  MLX_TURING_METAL_PHASE_UNSPECIFIED = 0,
  MLX_TURING_METAL_PHASE_WARM_LOAD = 1,
  MLX_TURING_METAL_PHASE_INITIAL_TALKER = 2,
  MLX_TURING_METAL_PHASE_DYNAMIC_TALKER = 3,
  MLX_TURING_METAL_PHASE_CODE_PREDICTOR = 4,
  MLX_TURING_METAL_PHASE_CPU_CODEBOOK_MATERIALIZATION = 5,
  MLX_TURING_METAL_PHASE_SPEECH_DECODER = 6,
  MLX_TURING_METAL_PHASE_CACHE_CLEAR = 7,
  MLX_TURING_METAL_PHASE_UNLOAD = 8,
  MLX_TURING_METAL_PHASE_OTHER = 9
} mlx_turing_metal_phase;

typedef struct mlx_turing_metal_context {
  char run_id[MLX_TURING_CONTEXT_RUN_ID_CAPACITY];
  char instance_id[MLX_TURING_CONTEXT_INSTANCE_ID_CAPACITY];
  char phase[MLX_TURING_CONTEXT_PHASE_CAPACITY];
  char stage[MLX_TURING_CONTEXT_STAGE_CAPACITY];
  char residency_owner_id[MLX_TURING_CONTEXT_RESIDENCY_ID_CAPACITY];
  char weight_store_id[MLX_TURING_CONTEXT_RESIDENCY_ID_CAPACITY];
  char lane_mutable_state_id[MLX_TURING_CONTEXT_RESIDENCY_ID_CAPACITY];
  int32_t segment_index;
  int32_t lane_index;
  int32_t decode_id;
  int32_t row_start_inclusive;
  int32_t row_end_exclusive;
  int32_t talker_position_start;
  int32_t talker_position_end;
  uint32_t app_metal_in_flight_count;
  uint32_t mind_eye_compositor_in_flight_count;
} mlx_turing_metal_context;

typedef struct mlx_turing_metal_configuration {
  int32_t device_initialized;
  char architecture[MLX_TURING_ARCHITECTURE_CAPACITY];
  int32_t architecture_generation;
  int32_t resolved_max_ops_per_buffer;
  int32_t resolved_max_mb_per_buffer;
} mlx_turing_metal_configuration;

typedef struct mlx_turing_command_buffer_record {
  uint64_t sequence;
  uint64_t command_buffer_id;
  uint64_t failure_epoch;
  int32_t stream_index;
  uintptr_t command_queue_identity;
  int32_t configured_max_ops;
  int32_t configured_max_mb;
  uint32_t encoded_operation_count;
  uint64_t referenced_input_bytes_estimate;
  uint32_t primitive_count;
  uint64_t primitive_name_hash;
  char first_primitive[MLX_TURING_PRIMITIVE_NAME_CAPACITY];
  char last_primitive[MLX_TURING_PRIMITIVE_NAME_CAPACITY];
  char command_buffer_label[MLX_TURING_COMMAND_BUFFER_LABEL_CAPACITY];
  mlx_turing_metal_context first_context;
  mlx_turing_metal_context last_context;
  int32_t mixed_context;
  uint64_t submit_uptime_nanoseconds;
  uint64_t completion_uptime_nanoseconds;
  double gpu_start_seconds;
  double gpu_end_seconds;
  double gpu_duration_seconds;
  double kernel_start_seconds;
  double kernel_end_seconds;
  double kernel_duration_seconds;
  int32_t completion_status;
  int32_t error_code;
  char error_domain[MLX_TURING_ERROR_DOMAIN_CAPACITY];
  char error_description[MLX_TURING_ERROR_DESCRIPTION_CAPACITY];
  uint32_t mlx_buffers_in_flight_at_submit;
  uint32_t app_metal_in_flight_at_submit;
  uint32_t mind_eye_in_flight_at_submit;
  uint64_t process_phys_footprint_bytes_at_submit;
  uint64_t process_available_memory_bytes_at_submit;
  uint64_t mlx_active_bytes_at_submit;
  uint64_t mlx_cache_bytes_at_submit;
  uint64_t mlx_peak_bytes_at_submit;
  uint64_t process_phys_footprint_bytes_at_completion;
  uint64_t process_available_memory_bytes_at_completion;
  uint64_t mlx_active_bytes_at_completion;
  uint64_t mlx_cache_bytes_at_completion;
  uint64_t mlx_peak_bytes_at_completion;
  int32_t is_failure;
  int32_t is_synthetic_test_failure;
} mlx_turing_command_buffer_record;

typedef struct mlx_turing_command_buffer_aggregate {
  uint64_t submitted_count;
  uint64_t completed_count;
  uint64_t failed_count;
  uint64_t maximum_encoded_operation_count;
  uint64_t maximum_referenced_input_bytes_estimate;
  double maximum_gpu_duration_seconds;
  double maximum_kernel_duration_seconds;
  uint64_t duration_bucket_lt_5ms;
  uint64_t duration_bucket_5_10ms;
  uint64_t duration_bucket_10_20ms;
  uint64_t duration_bucket_20_30ms;
  uint64_t duration_bucket_30_40ms;
  uint64_t duration_bucket_40_50ms;
  uint64_t duration_bucket_50_75ms;
  uint64_t duration_bucket_75_100ms;
  uint64_t duration_bucket_100_150ms;
  uint64_t duration_bucket_gte_150ms;
} mlx_turing_command_buffer_aggregate;

int mlx_turing_metal_set_context(const mlx_turing_metal_context* context);
void mlx_turing_metal_clear_context(void);
int mlx_turing_metal_copy_configuration(mlx_turing_metal_configuration* output);
int mlx_turing_metal_device_is_initialized(void);
uint64_t mlx_turing_metal_failure_epoch(void);
int mlx_turing_metal_is_poisoned(void);
int mlx_turing_metal_copy_last_failure(mlx_turing_command_buffer_record* output);
size_t mlx_turing_metal_copy_recent_records(
    mlx_turing_command_buffer_record* output,
    size_t output_capacity);
int mlx_turing_metal_copy_aggregate(mlx_turing_command_buffer_aggregate* output);
int mlx_turing_metal_set_failure_file_path(const char* utf8_path);
void mlx_turing_metal_set_external_in_flight_counts(
    uint32_t app_metal_count,
    uint32_t mind_eye_compositor_count);
void mlx_turing_metal_copy_external_in_flight_counts(
    uint32_t* app_metal_count,
    uint32_t* mind_eye_compositor_count);

/* Implemented only in MLX_TURING_TESTING builds; exported for Swift's Clang
 * importer because target-local C preprocessor defines are not re-exported. */
void mlx_turing_metal_test_reset(void);
void mlx_turing_metal_test_inject_failure_on_next_completion(
    int32_t metal_error_code);
void mlx_turing_metal_test_record_synthetic_completion(void);

#ifdef __cplusplus
}
#endif

#endif
