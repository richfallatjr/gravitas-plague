// Included once, by allocator.cpp, after its libc++ headers. No allocator logic.
#pragma once
#define MLX_TURING_STRING_INNER(x) #x
#define MLX_TURING_STRING(x) MLX_TURING_STRING_INNER(x)

#if defined(_LIBCPP_VERSION)
#define MLX_TURING_LIBCXX MLX_TURING_STRING(_LIBCPP_VERSION)
#else
#define MLX_TURING_LIBCXX "null"
#endif
#if defined(_LIBCPP_HARDENING_MODE) && defined(_LIBCPP_HARDENING_MODE_FAST)
#if _LIBCPP_HARDENING_MODE == _LIBCPP_HARDENING_MODE_FAST
#define MLX_TURING_HARDENING "fast"
#elif _LIBCPP_HARDENING_MODE == _LIBCPP_HARDENING_MODE_EXTENSIVE
#define MLX_TURING_HARDENING "extensive"
#elif _LIBCPP_HARDENING_MODE == _LIBCPP_HARDENING_MODE_DEBUG
#define MLX_TURING_HARDENING "debug"
#elif _LIBCPP_HARDENING_MODE == _LIBCPP_HARDENING_MODE_NONE
#define MLX_TURING_HARDENING "none"
#else
#define MLX_TURING_HARDENING "unknown"
#endif
#else
#define MLX_TURING_HARDENING "unknown"
#endif
#if defined(_LIBCPP_HARDENING_MODE_DEBUG) && _LIBCPP_HARDENING_MODE == _LIBCPP_HARDENING_MODE_DEBUG
#define MLX_TURING_INTERNAL_ASSERTS "true"
#elif defined(_LIBCPP_HARDENING_MODE)
#define MLX_TURING_INTERNAL_ASSERTS "false"
#else
#define MLX_TURING_INTERNAL_ASSERTS "null"
#endif
#ifdef __OPTIMIZE__
#define MLX_TURING_OPTIMIZED "true"
#else
#define MLX_TURING_OPTIMIZED "false"
#endif
#ifdef __OPTIMIZE_SIZE__
#define MLX_TURING_SIZE "true"
#else
#define MLX_TURING_SIZE "false"
#endif
#ifdef NDEBUG
#define MLX_TURING_NDEBUG "true"
#else
#define MLX_TURING_NDEBUG "false"
#endif
#ifdef MLX_TURING_TESTING
#define MLX_TURING_TESTING_JSON "true"
#else
#define MLX_TURING_TESTING_JSON "false"
#endif
#if defined(__arm64__) || defined(__aarch64__)
#define MLX_TURING_ARCH "arm64"
#elif defined(__x86_64__)
#define MLX_TURING_ARCH "x86_64"
#else
#define MLX_TURING_ARCH "unknown"
#endif
#ifndef MLX_TURING_HARDENING_EXPERIMENT
#define MLX_TURING_HARDENING_EXPERIMENT "unknown"
#endif
#ifndef __clang_version__
#define __clang_version__ "unknown"
#endif

extern "C" const char* mlx_turing_allocator_build_fingerprint_json(void) {
  return "{\"schemaVersion\":1,"
      "\"translationUnit\":\"mlx/mlx/backend/metal/allocator.cpp\","
      "\"compiler\":\"" __clang_version__ "\","
      "\"architecture\":\"" MLX_TURING_ARCH "\","
      "\"libcxxVersion\":" MLX_TURING_LIBCXX ","
      "\"hardeningMode\":\"" MLX_TURING_HARDENING "\","
      "\"internalAssertionsEnabled\":" MLX_TURING_INTERNAL_ASSERTS ","
      "\"optimized\":" MLX_TURING_OPTIMIZED ","
      "\"optimizeSize\":" MLX_TURING_SIZE ","
      "\"ndebug\":" MLX_TURING_NDEBUG ","
      "\"mlxTesting\":" MLX_TURING_TESTING_JSON ","
      "\"experimentID\":\"" MLX_TURING_HARDENING_EXPERIMENT "\"}";
}
