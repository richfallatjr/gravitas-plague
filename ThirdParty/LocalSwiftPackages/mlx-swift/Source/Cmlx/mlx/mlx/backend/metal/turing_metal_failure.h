#pragma once

#include <cstdint>
#include <stdexcept>

#include "mlx/c/turing_metal_diagnostics.h"

namespace mlx::core::metal::turing {

class TuringMetalCommandBufferFailure : public std::runtime_error {
 public:
  explicit TuringMetalCommandBufferFailure(
      const mlx_turing_command_buffer_record& record);

  uint64_t failure_epoch() const noexcept {
    return failure_epoch_;
  }

 private:
  uint64_t failure_epoch_;
};

void throw_if_turing_metal_failed();

} // namespace mlx::core::metal::turing
