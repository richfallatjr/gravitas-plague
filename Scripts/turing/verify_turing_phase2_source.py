#!/usr/bin/env python3
"""Fail closed when Phase 2 containment or the locked Fresh2 topology regresses."""

from __future__ import annotations

import argparse
from pathlib import Path


REQUIRED = {
    "ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/eval.cpp": [
        "noexcept", "throw_if_turing_metal_failed", "notify_task_completion"
    ],
    "ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/turing_command_buffer_diagnostics.cpp": [
        "complete_noexcept", "kCommandBufferRingCapacity", "poisoned_"
    ],
    "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeFreshInstanceScheduler.swift": [
        "lane0", "lane1", "qwen.run.cancelledForMetalFailure", "unloadAll"
    ],
    "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeGPUAdmissionPolicy.swift": [
        "maximumConcurrentGenerationLeases: Int = 2", "case currentOverlap"
    ],
    "Gravitas Plague/Gravitas Plague/GravitasPlagueApp.swift": [
        "TuringMLXCommandBufferStartup.configure()"
    ],
}

FORBIDDEN = {
    "ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/eval.cpp": [
        "throw std::runtime_error(error->localizedDescription"
    ],
}


def verify(root: Path) -> list[str]:
    failures: list[str] = []
    for relative, needles in REQUIRED.items():
        path = root / relative
        if not path.is_file():
            failures.append(f"missing file: {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        failures.extend(
            f"{relative}: missing required token {needle!r}"
            for needle in needles if needle not in text
        )
    for relative, needles in FORBIDDEN.items():
        path = root / relative
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            failures.extend(
                f"{relative}: forbidden token {needle!r}"
                for needle in needles if needle in text
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    arguments = parser.parse_args()
    failures = verify(arguments.root)
    if failures:
        print("FAIL")
        print("\n".join(failures))
        return 1
    print("PASS: Phase 2 source containment and Fresh2 topology are present.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
