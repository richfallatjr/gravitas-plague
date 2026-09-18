#!/usr/bin/env python3
"""Cheap A2 source tripwires; runtime tests/real trace remain separate gates."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


NATIVE = Path("Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative")
# Counts before A2. Wrapping an EXISTING materialization is allowed; adding
# materialization for measurement is not. A count guard is not a semantic proof.
MATERIALIZATION_BASELINES = {
    "BaseCloneEngine": 2,
    "TalkerLayer": 7,
    "CodePredictor": 2,
    "SpeechDecoder": 6,
    "Safetensors": 0,
    "SpeechDecodeCoordinator": 0,
    "FreshInstanceScheduler": 0,
}
REQUIRED_HOOKS = {
    "BaseCloneEngine": ("makeContext(", "$current.withValue(phaseContext)", "PromptConstructionCPU", "TalkerPrefillCPU", "GenerationRowCPU", "RenderTeardownCPU", "TuringQwenPerformanceBudget.check()"),
    "TalkerLayer": ("PrefillExistingEvalCPU", "talker.prompt.input", "talker.prefill.postRopeQ", "talker.prefill.postRopeK", "talker.step.postRopeQ", "talker.step.postRopeK", "talker.step.cacheK", "talker.step.cacheV", "talker.step.attentionOutput", "TuringQwenPerformanceBudget.check()"),
    "CodePredictor": ("ResidualGraphCPUEnqueue", "ResidualExistingReadbackCPU", "predictor.projectedInput", "predictor.logits", "predictor.cacheK", "predictor.cacheV"),
    "Safetensors": ("SafetensorsIndexIOCPU", "SafetensorsTensorIOCPU", "SafetensorsRowsIOCPU"),
    "SpeechDecoder": ("SpeechDecodeCPU", "DecoderStageExistingEvalCPU", "DecoderExistingPCMReadbackCPU", "decoder.pcm", "TuringQwenPerformanceBudget.check()"),
    "SpeechDecodeCoordinator": ("DecoderAdmissionWaitCPU", "PCMReady", "DecoderTeardownCPU"),
    "FreshInstanceScheduler": ("PCMDeliveryReady", "PCMDeliveryQueued"),
}


def verify(root: Path) -> list[str]:
    errors = []
    helper = (root / NATIVE / "TuringQwenNativePhaseDiagnostics.swift").read_text()
    required = (
        '@TaskLocal public static var enabled: Bool? = nil',
        'environment["TURING_QWEN_PHASE_DIAGNOSTICS"] == "1"',
        'public static var isEnabled: Bool { enabled ?? startupEnabled }',
        'guard isEnabled else { return nil }',
        '@TaskLocal public static var recordingSession: RecordingSession?',
        'ContinuousClock.now', 'droppedScopeCount', 'pendingScopeCount',
        'maximumScopes: Int = 8_192', 'maximumDetailCharacters = 512',
        'CPU scope (not GPU completion)',
        'OSSignpostID(log: log)', 'os_signpost(.begin', 'os_signpost(.end',
        'os_signpost(.event', 'maximumIntervals: Int = 512',
        'maximumPerPhase: Int = 32', 'maximumMetadata: Int = 128',
        'maximumShapesPerRole: Int = 4',
        'guard let context = current else { return }',
        'reserveInspection(role: roleName)', 'array: @autoclosure () -> MLXArray',
        'value.shape', 'value.dtype',
    )
    for token in required:
        if token not in helper:
            errors.append(f"diagnostics helper missing contract: {token}")
    for pattern in (r"\beval\s*\(", r"\.asArray\s*\(", r"\.item\s*\(",
                    r"\bsynchronize\s*\(", r"\bFileHandle\s*\(", r"\.write\s*\("):
        if re.search(pattern, helper):
            errors.append(f"diagnostics helper contains forbidden work: {pattern}")
    for name, baseline in MATERIALIZATION_BASELINES.items():
        source = (root / NATIVE / f"TuringQwenNative{name}.swift").read_text()
        count = len(re.findall(r"\beval\s*\(|\.asArray\s*\(|\.item\s*\(", source))
        if count > baseline:
            errors.append(f"{name}: materialization sites increased {baseline} -> {count}; audit for extra synchronization")
        for token in REQUIRED_HOOKS[name]:
            if token not in source:
                errors.append(f"{name}: required reachable diagnostic hook missing: {token}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    errors = verify(args.root)
    if errors:
        print("FAIL: " + "\n".join(errors))
        return 1
    print("PASS: A2 opt-in, bounded metadata/signposts, reachable hooks, no added materialization sites.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
