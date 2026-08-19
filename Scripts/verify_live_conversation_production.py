#!/usr/bin/env python3
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Gravitas Plague/Gravitas Plague"
RESOURCES = ROOT / "Gravitas Plague/TuringResources/Turing"


def fail(message: str) -> None:
    print(f"live conversation verifier: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_index(directory: Path, key: str) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for path in directory.glob("*.json"):
        if path.name == "catalog.json":
            continue
        value = json.loads(path.read_text())
        identifier = value.get(key)
        if identifier:
            if identifier in result:
                fail(f"duplicate {key}: {identifier}")
            result[identifier] = value
    return result


def effective_surface(transmission: dict) -> str:
    explicit = transmission.get("interactionSurface")
    if explicit:
        return explicit
    route = transmission.get("outputRoute")
    inferred = {
        "walkieSpatial": "walkie",
        "walkieOutgoingGlobal": "walkie",
        "crankRadioSpatial": "crankRadio",
        "hamReceiverSpatial": "hamReceiver",
        "roomGlobal": "dadFrame",
    }
    if route not in inferred:
        fail(f"cannot infer interaction surface for route {route}")
    return inferred[route]


def resolve_voice_prompt(entry: dict, transmission: dict) -> str:
    source = entry["voicePromptSource"]
    kind = source["kind"]
    if kind == "transmission":
        identifier = transmission.get("voicePromptID")
    elif kind == "explicit":
        identifier = source.get("voicePromptID")
    elif kind == "generationPipelineStage":
        stage_id = source.get("stageID")
        stages = (transmission.get("generationPipeline") or {}).get("stages", [])
        stage = next(
            (
                item for item in stages
                if item.get("stageID") == stage_id and item.get("kind") == "voicePrompt"
            ),
            None,
        )
        identifier = stage and stage.get("voicePromptID")
    else:
        identifier = None
    if not identifier:
        fail(f"unresolved VoicePrompt for {entry['scriptPointID']}")
    return identifier


def main() -> None:
    source = "\n".join(path.read_text() for path in APP.rglob("*.swift"))
    for forbidden in (
        "TuringStoryExperienceModePosterButtonComponent",
        "TuringStoryPosterExperienceModeIconController",
        "TuringStoryDeviceActivityIconController",
    ):
        if forbidden in source:
            fail(f"removed production UI owner remains referenced: {forbidden}")

    for match in re.finditer(r"(?:@AppStorage|UserDefaults)[^\n]*StoryExperienceMode", source):
        fail(f"Story experience mode is persisted: {match.group(0)}")

    episode = (APP / "Turing/Flow/TuringEpisodeFlowController.swift").read_text()
    if "TuringExperimentalPromptVoiceController.shared.isEnabled" not in episode:
        fail("developer PromptVoice path lacks its internal-only gate")
    if "if case .manualDebug = trigger" not in episode or episode.count(
        "capturedMode = .play"
    ) < 2:
        fail("normal authored execution is not hard-routed to Play")

    coordinator = (
        APP / "Turing/Conversation/TuringLiveConversationSessionCoordinator.swift"
    ).read_text()
    required = (
        "TuringFlowPlaybackLifecycleSink",
        "setPlaybackLifecycleSink(self)",
        "pauseCurrentSpokenMedia",
        "resumeCurrentSpokenMedia",
        "acquireAuthoredProgressionHold",
        "releaseAuthoredProgressionHold",
        "progressionPolicy: .neverAdvanceStory",
        "leasePolicy: .borrowedFromAuthoredFlow",
        "submittedQuestionHold: Duration = .seconds(2)",
        "waitingResponseTurnID",
        "pendingHoldSurface",
        "pendingHoldEndRequested",
        "let submitImmediately = pendingHoldEndRequested",
        "turn.selectedSurface == .dadFrame || turn.segmentZeroPrepared == false",
        "restoreAuthoredAvailabilityAfterOptionalFailure",
        "optional failure recovered",
        "restoreForOptionalFailureRetry",
        "prepareForPrerecordingPreFiller",
        "pre-filler microphones installed",
        "progressionHold: nil",
        "ensureProgressionHold",
        "authoredFlowDidComplete",
        "restoreRetainedAvailabilityIfPossible",
        "retained microphones restored",
        "replaceAttachmentPreservingRetainedAvailability",
    )
    for marker in required:
        if marker not in coordinator:
            fail(f"live coordinator missing production marker: {marker}")
    for forbidden in (
        "lifecycleTask",
        "notifyConversationPlaybackCompleted",
        "commitCheckpoint",
        "release(interactionLease",
        "responseSegmentZeroReady(clearAfterSeconds:",
    ):
        if forbidden in coordinator:
            fail(f"live coordinator contains forbidden ownership behavior: {forbidden}")

    walkie_filler_start = coordinator.find(
        "if turn.selectedSurface == .walkie {\n"
        "                await beginInitialFillerIfNeeded(turn)"
    )
    cover_waiter = coordinator.find(
        "let coverCompleted = await self.resumeAndWaitForSpokenCover(turn)"
    )
    helper_start = coordinator.find(
        "private func resumeAndWaitForSpokenCover("
    )
    filler_release = coordinator.find(
        "await prepareInitialFillerForSpokenPlayback(",
        helper_start,
    )
    cover_resume = coordinator.find(
        "try await turn.coverPlayback.resumeCurrentSpokenMedia(",
        helper_start,
    )
    if (
        min(
            walkie_filler_start,
            cover_waiter,
            helper_start,
            filler_release,
            cover_resume,
        ) < 0
        or walkie_filler_start > cover_waiter
        or filler_release > cover_resume
        or "mustEndBeforeSpokenCoverResumes == true" not in coordinator[
            helper_start:cover_resume
        ]
    ):
        fail("walkie send cover does not begin before resumed authored media")

    walkie_comms = (
        APP / "Turing/Audio/TuringWalkieCommsFXController.swift"
    ).read_text()
    for marker in (
        "await retainAmbientWalkieStatic(",
        "await worker.playSendCommAndStartSendingLeadIn(reason: reason)",
        "await worker.beginSendingLeadIn(reason: reason)",
        "await worker.stopSendingLeadIn(reason: reason)",
        "await releaseAmbientWalkieStatic(",
        "let ambientRetained = await retainAmbientWalkieStatic(",
        "randomBursts=true reason=",
    ):
        if marker not in walkie_comms:
            fail(f"live walkie send cover is incomplete: {marker}")

    conversation_runner = (
        APP / "Turing/Flow/TuringFlowConversationRunner.swift"
    ).read_text()
    for marker in (
        "TuringConversationResponsePlaybackLifecycleSink",
        "await playback.setPlaybackLifecycleSink(",
        "await request.lifecycleSink?.responsePlaybackOwnerReady(",
        "withExtendedLifetime(responsePlaybackLifecycleSink)",
    ):
        if marker not in conversation_runner:
            fail(f"conversation response playback missing direct lifecycle marker: {marker}")
    if "playbackLifecycleTask" in conversation_runner:
        fail("conversation response playback reverted to a task-based lifecycle observer")
    borrowed_gate_pattern = re.compile(
        r"switch request\.leasePolicy \{.*?"
        r"case \.ownedByConversation:.*?"
        r"\.beginConversation\(.*?"
        r"case \.borrowedFromAuthoredFlow\(.*?"
        r"gateOwnership: inheritedFromAuthoredFlow",
        re.DOTALL,
    )
    if borrowed_gate_pattern.search(conversation_runner) is None:
        fail(
            "borrowed live conversations can overwrite the authored flow gate owner"
        )

    authored_runner = (
        APP / "Turing/Flow/TuringAuthoredFlowRunner.swift"
    ).read_text()
    prefill_install = authored_runner.find(
        ".prepareForPrerecordingPreFiller(firstEligibleItem)"
    )
    fixed_lead_in = authored_runner.find(".runFixedLeadInIfNeeded(")
    route_open = authored_runner.find(".playOpenIfNeeded(")
    if min(prefill_install, fixed_lead_in, route_open) < 0 or not (
        prefill_install < fixed_lead_in < route_open
    ):
        fail("live microphones are not installed before authored pre-fillers")
    if ".authoredFlowDidComplete(" not in authored_runner:
        fail("normal authored completion does not retain applicable microphones")
    if (
        'detach(\n                reason: "authoredFlowCompleted.'
        in authored_runner
    ):
        fail("normal authored completion still detaches live microphones")

    playback_source = (
        APP / "Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
    ).read_text()
    for marker in (
        'itemIdentity: "prerecordingPreFiller"',
        "result: .completedBeforePause",
    ):
        if marker not in playback_source:
            fail(f"pre-filler microphone cannot create a valid cover receipt: {marker}")

    filler = (
        APP / "Turing/Conversation/TuringLiveConversationInitialFiller.swift"
    ).read_text()
    media_cues = (
        APP / "Turing/Flow/TuringFlowMediaCueCoordinator.swift"
    ).read_text()
    for marker in (
        "StoryMemoryMusicLiveGapToken",
        ".retainForLiveConversationGap(",
        ".releaseLiveConversationGap(",
    ):
        if marker not in filler:
            fail(f"Dad live-conversation score ownership is incomplete: {marker}")
    for marker in (
        "liveGapFlowByTokenID",
        "retainForLiveConversationGap",
        "releaseLiveConversationGap",
    ):
        if marker not in media_cues:
            fail(f"Dad score coordinator is missing live-gap retention: {marker}")

    play_actions = (
        APP / "Story/ExperienceMode/StoryModeActionCoordinator.swift"
    ).read_text()
    if "queue.first == action" not in play_actions:
        fail("play-mode queue head is not revalidated after the arbiter await")

    session_source = (APP / "PlagueDemoSession.swift").read_text()
    if "publishTuringDictationEvent(.questionDisplayExpired)" not in session_source:
        fail("expired live questions do not clear the transcript HUD")
    if 'processingStarted(finalTranscript: "...")' in session_source:
        fail("literal ellipsis is still routed through the full-width transcript HUD")

    immersive = (APP / "PlagueImmersiveCoordinator.swift").read_text()
    if immersive.count("scheduleTuringHUDClear(") < 3:
        fail("dictation and response failures do not self-clear from the HUD")

    foundation = (
        APP / "Turing/Foundation/TuringFoundationModelsRunner.swift"
    ).read_text()
    for marker in (
        'purpose.hasPrefix("conversationPrompt_")',
        "return .permissiveContentTransformations",
    ):
        if marker not in foundation:
            fail(f"conversationVoice is not uniformly permissive: {marker}")

    live_router = (
        APP / "Turing/Conversation/TuringStoryLiveMicrophoneActionRouter.swift"
    ).read_text()
    if "coordinator.ownsMicrophoneHold(surface: surface)" not in live_router:
        fail("duplicate live microphone begins can fall through to the legacy claim path")

    icon_style = (
        APP / "Turing/Interaction/TuringStoryActionIconVisualStyle.swift"
    ).read_text()
    if "clip(to: inset, mask: glyph)" in icon_style:
        fail("Story SF Symbols are still stretched into a square Core Graphics mask")
    for marker in (
        "makeGradientGlyphImage",
        "alignmentCenteredDrawRect",
        "blendMode: .destinationIn",
        "symbol.alignmentRectInsets",
    ):
        if marker not in icon_style:
            fail(f"Story action glyph gradient/alignment is incomplete: {marker}")

    walkie_icon = (
        APP / "Turing/Interaction/TuringStoryPropBillboardIconController.swift"
    ).read_text()
    for marker in (
        "walkieIconWorldUpOffsetMeters: Float = 0.0508",
        "icon.setPosition(",
        "iconWorldUpOffsetMeters:",
    ):
        if marker not in walkie_icon:
            fail(f"walkie icon two-inch world-up offset is missing: {marker}")

    playback = (
        APP / "Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
    ).read_text()
    require_awaited_sink = (
        "await playbackLifecycleSink?.receivePlaybackLifecycleEvent(event)",
        "await lifecycleHub.yield(event)",
    )
    sink_cursor = -1
    for marker in require_awaited_sink:
        sink_cursor = playback.find(marker, sink_cursor + 1)
        if sink_cursor < 0:
            fail(f"playback lifecycle sink is not awaited before telemetry: {marker}")

    catalog = json.loads((RESOURCES / "LiveConversation/catalog.json").read_text())
    if catalog.get("schemaVersion") != 1:
        fail("live catalog schemaVersion must be 1")
    entries = catalog.get("entries", [])
    keys = [
        (entry["scriptPointID"], entry["authoredPrerecordingID"])
        for entry in entries
    ]
    if len(keys) != len(set(keys)):
        fail("live catalog contains duplicate script/PR keys")

    scripts = load_index(RESOURCES / "ScriptPoints", "scriptPointID")
    prerecordings = load_index(RESOURCES / "Prerecordings", "prerecordingID")
    prompts = load_index(RESOURCES / "VoicePrompts", "voicePromptID")
    for entry in entries:
        script_id = entry["scriptPointID"]
        if script_id not in scripts:
            fail(f"missing ScriptPoint: {script_id}")
        transmission = scripts[script_id]["transmission"]
        pr_id = entry["authoredPrerecordingID"]
        prerecording = prerecordings.get(pr_id)
        if not prerecording:
            fail(f"missing prerecording: {pr_id}")
        if prerecording.get("transcriptMode") != "manual" or not prerecording.get(
            "transcript", ""
        ).strip():
            fail(f"live prerecording lacks an authored transcript: {pr_id}")
        if effective_surface(transmission) != entry["interactionSurface"]:
            fail(f"surface mismatch for {script_id}")

        voice_prompt_id = resolve_voice_prompt(entry, transmission)
        prompt = prompts.get(voice_prompt_id)
        if not prompt:
            fail(f"missing VoicePrompt: {voice_prompt_id}")
        expected = (
            transmission["characterID"],
            transmission["conversationKey"],
            transmission["outputRoute"],
        )
        actual = (
            prompt["speakerID"],
            prompt["conversationKey"],
            prompt["outputContext"],
        )
        if actual != expected:
            fail(f"VoicePrompt identity mismatch for {script_id}: {actual} != {expected}")

    script05_key = (
        "prologue.scriptPoint05",
        "prologue.walkie.bigMike.scriptPoint05.002",
    )
    script05 = next((entry for entry in entries if tuple(entry[k] for k in (
        "scriptPointID", "authoredPrerecordingID"
    )) == script05_key), None)
    if not script05:
        fail("ScriptPoint05 second-PR live mapping is missing")
    if script05["voicePromptSource"] != {
        "kind": "generationPipelineStage",
        "stageID": "promptVoice",
        "voicePromptID": None,
    }:
        fail("ScriptPoint05 must source promptVoice from the generation pipeline")
    if script05["retention"] != "untilExplicitInvalidation":
        fail("ScriptPoint05 must retain its second-PR seed until explicit invalidation")
    expiring_entries = [
        entry for entry in entries
        if entry["retention"] != "untilExplicitInvalidation"
    ]
    if expiring_entries:
        fail(
            "Every eligible device microphone must survive authored playback; "
            f"expiring entries: {[entry['scriptPointID'] for entry in expiring_entries]}"
        )
    if any(
        entry["scriptPointID"] == "prologue.scriptPoint05"
        and entry["authoredPrerecordingID"].endswith(".001")
        for entry in entries
    ):
        fail("ScriptPoint05 first PR must not become its conversation seed")

    print(
        "live conversation verifier: OK "
        f"entries={len(entries)} uniqueKeys={len(set(keys))} script05=PR002/promptVoice"
    )


if __name__ == "__main__":
    main()
