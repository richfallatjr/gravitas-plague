#!/usr/bin/env python3
"""Fail closed when the Phase 2R recovery contract is weakened."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


QWEN = Path(
    "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/"
    "TuringQwenNative"
)
APP_TURING = Path("Gravitas Plague/Gravitas Plague/Turing")
MLX = Path("ThirdParty/LocalSwiftPackages/mlx-swift/Source")

REQUIRED: dict[Path, tuple[str, ...]] = {
    QWEN / "TuringQwenNativeGenerationSchedulerFactory.swift": (
        "exactFreshInstanceCount = 2",
    ),
    QWEN / "TuringQwenNativeGPUAdmissionPolicy.swift": (
        "case currentOverlap",
        ".currentOverlap",
    ),
    QWEN / "TuringQwenNativeRecoveryCoordinator.swift": (
        "recordFirstFailure",
        "beginAfterOwnershipRelease",
        "Task.detached",
        "waitForQuiescence",
        "resetStreams",
        "runProbe",
        "finish",
        "markUnavailable",
        "isPublishable",
    ),
    QWEN / "TuringQwenNativeRecoveryPolicy.swift": (
        "maximumAttemptsPerFailure: 1",
        "maximumAttemptsPerLaunch: 3",
        "maximumAttemptsPerLaunch: 12",
        "GR_TURING_METAL_STREAM_RECOVERY",
        "GR_TURING_METAL_RECOVERY_QUALIFICATION",
    ),
    QWEN / "TuringQwenNativeRecoveryReceipt.swift": (
        "laneReceipts.count == 2",
        "decoderReceipt.isComplete",
        "admissionReceipt.isComplete",
        "queueCancelled",
        "releaseLedgerCleared",
    ),
    QWEN / "TuringQwenNativeFreshInstance.swift": (
        "recoveryGeneration",
        "activeRenderCount",
    ),
    QWEN / "TuringQwenNativeFreshInstancePool.swift": (
        "recoveryGeneration",
        "unloadForRecovery",
        "metalRecovery.finalOwnershipReconciliation",
    ),
    QWEN / "TuringQwenNativeFreshInstanceScheduler.swift": (
        "recoveryGeneration",
        "cancelAndReleaseForRecovery",
        "cancelForRecovery",
        "isPublishable",
    ),
    QWEN / "TuringQwenNativeSpeechDecodeCoordinator.swift": (
        "recoveryGeneration",
        "cancelAndReleaseForRecovery",
        "private var activeRun: ActiveRun?",
    ),
    QWEN / "TuringQwenRenderedCodebookSegment.swift": (
        "recoveryGeneration",
    ),
    QWEN / "TuringQwenDecodedSegment.swift": (
        "recoveryGeneration",
    ),
    APP_TURING / "Flow/TuringFlowPlaybackControlling.swift": (
        "qwenComputeFailed",
    ),
    MLX / "Cmlx/include/mlx/c/turing_metal_recovery.h": (
        "mlx_turing_metal_recovery_begin",
        "mlx_turing_metal_recovery_wait_for_quiescence",
        "mlx_turing_metal_recovery_reset_streams",
        "mlx_turing_metal_recovery_run_probe",
        "mlx_turing_metal_recovery_finish",
    ),
    MLX / "Cmlx/mlx/mlx/backend/metal/turing_metal_recovery.cpp": (
        "acquire_execution",
        "active_execution_count_ == 0",
        "in_flight_count_ == 0",
        "reset_streams_for_turing_recovery",
        "acknowledge_failure_for_recovery",
        "copyFromBuffer",
    ),
    MLX / "Cmlx/mlx/mlx/backend/metal/device.cpp": (
        "reset_streams_for_turing_recovery",
        "recovery_generation",
        "dispose()",
    ),
    MLX / "MLX/TuringMetalRecovery.swift": (
        "public enum TuringMetalRecovery",
        "waitForQuiescence",
        "resetStreams",
        "runProbe",
    ),
}

FORBIDDEN_TOKENS = (
    "recoverForFreshPoolWarmLoad",
    "acknowledgeFailureForRecovery",
    "mlx_turing_metal_acknowledge_failure_for_recovery",
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def verify(root: Path) -> list[str]:
    failures: list[str] = []
    for relative, tokens in REQUIRED.items():
        path = root / relative
        if not path.is_file():
            failures.append(f"missing file: {relative}")
            continue
        source = read(path)
        for token in tokens:
            if token not in source:
                failures.append(f"{relative}: missing required token {token!r}")

    scanned_roots = (root / APP_TURING, root / MLX)
    for scanned_root in scanned_roots:
        for path in scanned_root.rglob("*"):
            if not path.is_file() or path.suffix not in {".swift", ".h", ".cpp", ".c"}:
                continue
            source = read(path)
            for token in FORBIDDEN_TOKENS:
                if token in source:
                    failures.append(
                        f"{path.relative_to(root)}: forbidden recovery shortcut {token!r}"
                    )

    recovery = read(root / QWEN / "TuringQwenNativeRecoveryCoordinator.swift")
    if "@MainActor" in recovery:
        failures.append("recovery coordinator must not be MainActor-isolated")

    mind_eye = root / APP_TURING / "MindsEye"
    if mind_eye.is_dir():
        prohibited = re.compile(
            r"(?is)(metal|qwen).*recovery.{0,120}(release|evict|detach|teardown)"
        )
        for path in mind_eye.rglob("*.swift"):
            if prohibited.search(read(path)):
                failures.append(
                    f"{path.relative_to(root)}: recovery-driven Mind's Eye teardown"
                )

    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repository-root",
        "--root",
        dest="root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    args = parser.parse_args()
    failures = verify(args.root.resolve())
    if failures:
        print("FAIL")
        print("\n".join(failures))
        return 1
    print("PASS: Phase 2R recovery ownership and locked Fresh2 topology verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
