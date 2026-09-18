#ifndef MLX_C_TURING_BUILD_FINGERPRINT_H
#define MLX_C_TURING_BUILD_FINGERPRINT_H

#ifdef __cplusplus
extern "C" {
#endif

// Static JSON owned by the library. No device initialization or allocation.
// Defined by the allocator translation unit after its actual libc++ includes.
const char* mlx_turing_allocator_build_fingerprint_json(void);

#ifdef __cplusplus
}
#endif
#endif
