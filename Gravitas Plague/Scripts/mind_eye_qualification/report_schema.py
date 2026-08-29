from __future__ import annotations

import math
import uuid
from typing import Any

SCENARIOS = {
    "controlStoryScene", "coldPackagePrewarm", "authoredBigMikeAllTen",
    "generatedPromptVoice", "generatedConversationVoice", "qwenControlNoMindEye",
    "qwenOverlapWithMindEye", "authoredSecondRun", "generatedSecondRun",
    "pauseResume", "inactiveActive", "backgroundActive", "memoryWarning",
    "memoryCritical", "physicalMikeSuppression", "operationModeTeardown",
    "immersiveShutdown", "tenCycleStress", "xcodeDebugOverhead",
    "videoCaptureOverhead", "testFlightEquivalent",
}
CONFIGURATIONS = {
    "releaseNoDebugger", "releaseWithCapture", "debugWithXcode", "testFlight"
}
FEATURE_MODES = {"enabled", "disabledControl"}
CHECKPOINTS = {
    "appCold", "immersiveEntered", "storySystemsReady", "beforePackagePrewarm",
    "afterPackagePrewarm", "beforeVisualAttach", "afterVisualAttach",
    "authoredAudioStarted", "authoredMouthStarted", "generatedPCMReady",
    "generatedAnalysisReady", "generatedAudioStarted", "generatedMouthStarted",
    "qwenPreflightBefore", "qwenPreflightAfter", "qwenGenerationPeak",
    "speechCompleted", "visualDismissed", "sourceReferencesReleased",
    "twoSecondsAfterRelease", "fiveSecondsAfterRelease",
    "fifteenSecondsAfterRelease", "thirtySecondsAfterRelease",
    "operationModeTornDown", "immersiveShutDown",
}
REPEATABLE_SCENARIOS = {
    "authoredBigMikeAllTen", "generatedPromptVoice",
    "generatedConversationVoice", "tenCycleStress",
}
REQUIRED_CHECKPOINTS = {
    "controlStoryScene": {"appCold", "immersiveEntered", "storySystemsReady"},
    "coldPackagePrewarm": {"beforePackagePrewarm", "afterPackagePrewarm"},
    "authoredBigMikeAllTen": {
        "authoredAudioStarted", "authoredMouthStarted", "speechCompleted",
        "visualDismissed", "sourceReferencesReleased",
    },
    "generatedPromptVoice": {
        "generatedPCMReady", "generatedAudioStarted", "generatedMouthStarted",
        "speechCompleted", "sourceReferencesReleased",
    },
    "generatedConversationVoice": {
        "generatedPCMReady", "generatedAudioStarted", "generatedMouthStarted",
        "speechCompleted", "sourceReferencesReleased",
    },
    "qwenControlNoMindEye": {
        "qwenPreflightBefore", "qwenPreflightAfter", "qwenGenerationPeak",
    },
    "qwenOverlapWithMindEye": {
        "qwenPreflightBefore", "qwenPreflightAfter", "qwenGenerationPeak",
    },
    "operationModeTeardown": {"operationModeTornDown"},
    "immersiveShutdown": {"immersiveShutDown"},
}
TEARDOWN_CHECKPOINTS = {
    "sourceReferencesReleased", "operationModeTornDown", "immersiveShutDown",
}
COUNT_FIELDS = {
    "sourceTextureCount", "sourceTextureAllocatedBytes", "outputTextureCount",
    "outputTextureAllocatedBytes", "activeAssetPackageCount",
    "inactiveAssetPackageCount", "cachedAuthoredTrackCount",
    "activeAuthoredTrackLeaseCount", "motionRegistryCount",
    "authoredRegistryCount", "generatedRegistryCount", "activeCardCount",
    "orphanCardCount", "compositorInFlightCount", "compositorPendingFrameCount",
    "cropClampCount", "coalescedFrameCount", "authoredCompactFrameBytes",
    "generatedCompactFrameBytes",
}


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _validate_run(run: Any, prefix: str, errors: list[str]) -> None:
    if not isinstance(run, dict):
        errors.append(f"{prefix} must be an object")
        return
    try:
        uuid.UUID(str(run.get("id", "")))
    except ValueError:
        errors.append(f"{prefix}.id must be a UUID")
    if run.get("scenario") not in SCENARIOS:
        errors.append(f"{prefix}.scenario is unknown")
    if run.get("configuration") not in CONFIGURATIONS:
        errors.append(f"{prefix}.configuration is unknown")
    sequence = run.get("sequenceNumber")
    if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
        errors.append(f"{prefix}.sequenceNumber must be nonnegative")


def validate_report(document: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, dict):
        return ["report must be an object"]
    if document.get("schemaVersion") != 1:
        errors.append("schemaVersion must equal 1")
    if document.get("reportVersion") != "mind-eye-release-qualification/1":
        errors.append("reportVersion is unsupported")
    if document.get("generatedAtUTC") is not None:
        errors.append("generatedAtUTC must be null in the deterministic report")
    run = document.get("run")
    _validate_run(run, "run", errors)
    events = document.get("events")
    if not isinstance(events, list):
        errors.append("events must be an array")
        return errors
    last_time = -1
    seen: set[str] = set()
    scenario = run.get("scenario") if isinstance(run, dict) else None
    for index, event in enumerate(events):
        prefix = f"events[{index}]"
        if not isinstance(event, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if event.get("schemaVersion") != 1:
            errors.append(f"{prefix}.schemaVersion must equal 1")
        if event.get("ordinal") != index:
            errors.append(f"{prefix}.ordinal must equal {index}")
        if event.get("run") != run:
            errors.append(f"{prefix}.run does not match report run")
        checkpoint = event.get("checkpoint")
        if checkpoint not in CHECKPOINTS:
            errors.append(f"{prefix}.checkpoint is unknown")
        elif checkpoint in seen and scenario not in REPEATABLE_SCENARIOS:
            errors.append(f"{prefix}.checkpoint is duplicated")
        seen.add(str(checkpoint))
        elapsed = event.get("continuousNanosecondsSinceRunStart")
        if not isinstance(elapsed, int) or isinstance(elapsed, bool) or elapsed < 0:
            errors.append(f"{prefix}.continuousNanosecondsSinceRunStart is invalid")
        elif elapsed < last_time:
            errors.append(f"{prefix}.continuous time is not monotonic")
        else:
            last_time = elapsed
        resource = event.get("resource")
        if not isinstance(resource, dict):
            errors.append(f"{prefix}.resource must be an object")
        else:
            for name in COUNT_FIELDS:
                value = resource.get(name)
                if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                    errors.append(f"{prefix}.resource.{name} must be nonnegative")
            process = resource.get("process")
            if not isinstance(process, dict) or not isinstance(
                process.get("physicalFootprintBytes"), int
            ) or process.get("physicalFootprintBytes", -1) < 0:
                errors.append(f"{prefix}.resource.process is invalid")
            if checkpoint in TEARDOWN_CHECKPOINTS:
                for name in (
                    "activeAssetPackageCount", "activeAuthoredTrackLeaseCount",
                    "motionRegistryCount", "authoredRegistryCount",
                    "generatedRegistryCount", "activeCardCount", "orphanCardCount",
                ):
                    if resource.get(name) != 0:
                        errors.append(f"{prefix}.resource.{name} must be zero after teardown")
        timing = event.get("timing")
        if not isinstance(timing, dict):
            errors.append(f"{prefix}.timing must be an object")
        else:
            for name, value in timing.items():
                if value is not None and (not _is_number(value) or not math.isfinite(value)):
                    errors.append(f"{prefix}.timing.{name} must be finite or null")
        notes = event.get("notes")
        if not isinstance(notes, list) or notes != sorted(notes):
            errors.append(f"{prefix}.notes must be a sorted array")
    missing = REQUIRED_CHECKPOINTS.get(str(scenario), set()) - seen
    if missing:
        errors.append("missing required checkpoints: " + ", ".join(sorted(missing)))
    return errors
