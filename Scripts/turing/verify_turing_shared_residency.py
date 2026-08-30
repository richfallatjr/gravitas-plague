#!/usr/bin/env python3
"""Fail closed when Phase 3 shared immutable residency regresses."""

from __future__ import annotations

import argparse
from pathlib import Path


SOURCE = Path(
    "Gravitas Plague/Gravitas Plague/Turing/QwenNative/"
    "Sources/TuringQwenNative"
)

REQUIRED: dict[Path, tuple[str, ...]] = {
    SOURCE / "TuringQwenNativeResidencyMode.swift": (
        "case independentFresh2",
        "case sharedImmutableFresh2",
        "case singleLaneSharedControl",
    ),
    SOURCE / "TuringQwenNativeWeightsStore.swift": (
        "final class TuringQwenNativeWeightsStore",
        "let identity = UUID()",
        "let tensorCount: Int",
        "func makeLaneLocalRows",
    ),
    SOURCE / "TuringQwenNativeSharedResidencyOwner.swift": (
        "TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy",
        "finished with active lane leases",
        "TuringQwenNativeResidencyLeaseRegistry",
        "captureSharedWeightQualificationSnapshot",
    ),
    SOURCE / "TuringQwenNativeSharedWeightQualificationGuard.swift": (
        "#if GR_TURING_QUALIFICATION",
        "talker.model.text_embedding.weight",
        "talker.model.layers.0.self_attn.q_proj.weight",
        "talker.model.layers.0.mlp.gate_proj.weight",
        "talker.code_predictor.model.layers.0.self_attn.q_proj.weight",
        "deterministicScalarIndices",
    ),
    SOURCE / "TuringQwenNativeResidencyLeaseRegistry.swift": (
        "already has two active lane leases",
        "already has a lease for",
        "Duplicate shared residency lease release",
    ),
    SOURCE / "TuringQwenNativeFreshInstancePool.swift": (
        "requestedInstanceCount == 2",
        "fallbackAllowed == false",
        "validateSharedPool",
        "owner.finish",
        "sharedResidency.ownerReleased",
    ),
    SOURCE / "TuringQwenNativeFreshInstanceScheduler.swift": (
        "requested == 2, actual == 2",
        "TuringQwenNativeGPUAdmissionController",
        "TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy",
        "verifySharedWeightsUnchangedAfterQualificationRun",
        "qualificationSingleLaneControl",
    ),
    SOURCE / "TuringQwenNativeSingleLaneResidencyControl.swift": (
        "#if GR_TURING_QUALIFICATION",
        "requestedInstanceCount: 1",
        "qualificationSingleLaneInstancePool",
        "scheduler.runSegments",
        "pool.unloadAll",
    ),
    SOURCE / "TuringQwenNativeBaseCloneEngine.swift": (
        "case shared(lease:",
        "resolveConditioning",
        "releaseLaneState",
        "laneMutableStateIdentity",
    ),
    Path(
        "Gravitas Plague/Gravitas Plague/Turing/Flow/"
        "TuringQwenResidencyExperimentConfiguration.swift"
    ): (
        "GR_TURING_SHARED_RESIDENCY",
        "GR_TURING_QUALIFICATION",
        "return Self(mode: .independentFresh2)",
    ),
    Path(
        "ThirdParty/LocalSwiftPackages/mlx-swift/Source/MLX/"
        "TuringMetalDiagnostics.swift"
    ): (
        "residencyOwnerID",
        "weightStoreID",
        "laneMutableStateID",
    ),
}


def method_body(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        return ""
    brace = text.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace : index + 1]
    return ""


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
            for needle in needles
            if needle not in text
        )

    fresh_path = root / SOURCE / "TuringQwenNativeFreshInstance.swift"
    if fresh_path.is_file():
        text = fresh_path.read_text(encoding="utf-8")
        shared = method_body(text, "public func warmLoadShared(")
        unload = method_body(text, "public func unloadLaneState(")
        for forbidden in (
            "MLX.loadArrays",
            "CloneArtifactsLoader",
            "TuringQwenNativeResidentResources(",
        ):
            if forbidden in shared:
                failures.append(
                    f"TuringQwenNativeFreshInstance.warmLoadShared contains {forbidden!r}"
                )
        if "clearCache(" in unload:
            failures.append("shared lane-state unload clears the process-wide MLX cache")

    engine_path = root / SOURCE / "TuringQwenNativeBaseCloneEngine.swift"
    if engine_path.is_file():
        engine = engine_path.read_text(encoding="utf-8")
        shared_init = method_body(engine, "public init(\n        sharedResidencyLease:")
        if "TuringQwenNativeResidentResources(" in shared_init:
            failures.append("shared BaseCloneEngine initializer contains a fallback resource load")

    owner_path = root / SOURCE / "TuringQwenNativeSharedResidencyOwner.swift"
    if owner_path.is_file():
        owner = owner_path.read_text(encoding="utf-8")
        for forbidden in ("staticPromptContexts", "KVCache", "samplerState"):
            if forbidden in owner:
                failures.append(f"shared residency owner contains mutable lane state {forbidden!r}")

    app_root = root / "Gravitas Plague/Gravitas Plague"
    for path in app_root.rglob("*.swift"):
        if path.name in {
            "TuringQwenNativeParallelLanePool.swift",
            "TuringQwenNativeParallelScheduler.swift",
        } or "Tests" in path.parts or "Debug" in path.parts:
            continue
        if "TuringQwenNativeParallelLanePool(" in path.read_text(encoding="utf-8"):
            failures.append(f"production app constructs legacy parallel lane pool: {path}")

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
    arguments = parser.parse_args()
    failures = verify(arguments.root.resolve())
    if failures:
        print("FAIL")
        print("\n".join(failures))
        return 1
    print("PASS: Phase 3 shared immutable residency source contracts are present.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
