#include "mlx/c/turing_metal_diagnostics.h"

#include "mlx/backend/metal/turing_command_buffer_diagnostics.h"

using mlx::core::metal::turing::clear_context;
using mlx::core::metal::turing::diagnostics;
using mlx::core::metal::turing::set_context;

extern "C" int mlx_turing_metal_set_context(
    const mlx_turing_metal_context* context) {
  if (!context) {
    return 1;
  }
  set_context(*context);
  return 0;
}

extern "C" void mlx_turing_metal_clear_context(void) {
  clear_context();
}

extern "C" int mlx_turing_metal_copy_configuration(
    mlx_turing_metal_configuration* output) {
  return output && diagnostics().copy_configuration(*output) ? 0 : 1;
}

extern "C" int mlx_turing_metal_device_is_initialized(void) {
  return diagnostics().device_is_initialized() ? 1 : 0;
}

extern "C" uint64_t mlx_turing_metal_failure_epoch(void) {
  return diagnostics().failure_epoch();
}

extern "C" int mlx_turing_metal_is_poisoned(void) {
  return diagnostics().is_poisoned() ? 1 : 0;
}

extern "C" int mlx_turing_metal_copy_last_failure(
    mlx_turing_command_buffer_record* output) {
  return output && diagnostics().copy_last_failure(*output) ? 0 : 1;
}

extern "C" size_t mlx_turing_metal_copy_recent_records(
    mlx_turing_command_buffer_record* output,
    size_t output_capacity) {
  return diagnostics().copy_recent_records(output, output_capacity);
}

extern "C" int mlx_turing_metal_copy_aggregate(
    mlx_turing_command_buffer_aggregate* output) {
  if (!output) {
    return 1;
  }
  diagnostics().copy_aggregate(*output);
  return 0;
}

extern "C" int mlx_turing_metal_set_failure_file_path(
    const char* utf8_path) {
  return diagnostics().set_failure_path(utf8_path) ? 0 : 1;
}

extern "C" void mlx_turing_metal_set_external_in_flight_counts(
    uint32_t app_metal_count,
    uint32_t mind_eye_compositor_count) {
  diagnostics().set_external_in_flight_counts(
      app_metal_count,
      mind_eye_compositor_count);
}

extern "C" void mlx_turing_metal_copy_external_in_flight_counts(
    uint32_t* app_metal_count,
    uint32_t* mind_eye_compositor_count) {
  if (!app_metal_count || !mind_eye_compositor_count) {
    return;
  }
  diagnostics().copy_external_in_flight_counts(
      *app_metal_count,
      *mind_eye_compositor_count);
}

#ifdef MLX_TURING_TESTING
extern "C" void mlx_turing_metal_test_reset(void) {
  diagnostics().test_reset();
}

extern "C" void mlx_turing_metal_test_inject_failure_on_next_completion(
    int32_t metal_error_code) {
  diagnostics().test_inject_failure_on_next_completion(metal_error_code);
}

extern "C" void mlx_turing_metal_test_record_synthetic_completion(void) {
  diagnostics().test_record_synthetic_completion();
}
#endif
