import copy
import uuid

from mind_eye_qualification.report_schema import validate_report


def minimal_report():
    run = {
        "id": str(uuid.UUID(int=1)),
        "scenario": "controlStoryScene",
        "configuration": "releaseNoDebugger",
        "sequenceNumber": 0,
    }
    events = []
    for ordinal, checkpoint in enumerate(("appCold", "immersiveEntered", "storySystemsReady")):
        events.append({
            "schemaVersion": 1,
            "run": run,
            "ordinal": ordinal,
            "checkpoint": checkpoint,
            "continuousNanosecondsSinceRunStart": ordinal,
            "playbackRunID": None,
            "mediaIdentity": None,
            "speakerCharacterID": None,
            "interactionSurface": None,
            "resource": resource(),
            "timing": timing(),
            "notes": [],
        })
    return {
        "schemaVersion": 1,
        "reportVersion": "mind-eye-release-qualification/1",
        "run": run,
        "events": events,
        "generatedAtUTC": None,
    }


def resource():
    result = {name: 0 for name in (
        "sourceTextureCount sourceTextureAllocatedBytes outputTextureCount "
        "outputTextureAllocatedBytes activeAssetPackageCount inactiveAssetPackageCount "
        "cachedAuthoredTrackCount activeAuthoredTrackLeaseCount motionRegistryCount "
        "authoredRegistryCount generatedRegistryCount activeCardCount orphanCardCount "
        "compositorInFlightCount compositorPendingFrameCount cropClampCount "
        "coalescedFrameCount authoredCompactFrameBytes generatedCompactFrameBytes"
    ).split()}
    result.update({"process": {"physicalFootprintBytes": 1}, "vignetteID": None})
    return result


def timing():
    return {name: None for name in (
        "actualAudioStartLatencyMilliseconds visualReadyAfterActualStartMilliseconds "
        "generatedAnalysisMilliseconds motionSystemCPUP50Milliseconds "
        "motionSystemCPUP95Milliseconds authoredSystemCPUP50Milliseconds "
        "authoredSystemCPUP95Milliseconds generatedSystemCPUP50Milliseconds "
        "generatedSystemCPUP95Milliseconds compositorEncodeP50Milliseconds "
        "compositorEncodeP95Milliseconds compositorGPUP50Milliseconds "
        "compositorGPUP95Milliseconds frameIntervalMilliseconds "
        "mainThreadFrameP95Milliseconds"
    ).split()}


def test_valid_report_passes():
    assert validate_report(minimal_report()) == []


def test_nonmonotonic_report_fails():
    report = copy.deepcopy(minimal_report())
    report["events"][2]["continuousNanosecondsSinceRunStart"] = 0
    assert any("not monotonic" in error for error in validate_report(report))
