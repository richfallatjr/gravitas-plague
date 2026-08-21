#!/usr/bin/env python3
"""Static production checks for deterministic, latched conversation routing."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Gravitas Plague/Gravitas Plague"
RESOURCES = ROOT / "Gravitas Plague/TuringResources/Turing"
CATALOG_PATH = RESOURCES / "LiveConversation/catalog.json"


def fail(message: str) -> None:
    print(f"deterministic microphone routing: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_index(directory: Path, key: str) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for path in sorted(directory.glob("*.json")):
        value = json.loads(path.read_text())
        identifier = value.get(key)
        if not identifier:
            continue
        if identifier in result:
            fail(f"duplicate {key}: {identifier}")
        result[identifier] = value
    return result


def effective_surface(transmission: dict) -> str:
    if transmission.get("interactionSurface"):
        return transmission["interactionSurface"]
    routes = {
        "walkieSpatial": "walkie",
        "walkieOutgoingGlobal": "walkie",
        "crankRadioSpatial": "crankRadio",
        "hamReceiverSpatial": "hamReceiver",
        "roomGlobal": "dadFrame",
    }
    route = transmission.get("outputRoute")
    if route not in routes:
        fail(f"cannot infer interaction surface for route {route}")
    return routes[route]


def resolve_voice_prompt_id(moment: dict, script_point: dict) -> str:
    source = moment["voicePromptSource"]
    kind = source["kind"]
    transmission = script_point["transmission"]
    if kind == "transmission":
        identifier = transmission.get("voicePromptID")
    elif kind == "explicit":
        identifier = source.get("voicePromptID")
    elif kind == "generationPipelineStage":
        stage_id = source.get("stageID")
        stages = (transmission.get("generationPipeline") or {}).get("stages", [])
        stage = next(
            (
                value
                for value in stages
                if value.get("stageID") == stage_id
                and value.get("kind") == "voicePrompt"
            ),
            None,
        )
        identifier = stage and stage.get("voicePromptID")
    else:
        identifier = None
    if not identifier:
        fail(f"cannot resolve VoicePrompt for {moment['momentID']}")
    return identifier


def validate_catalog() -> None:
    catalog = json.loads(CATALOG_PATH.read_text())
    if catalog.get("schemaVersion") != 2:
        fail("routing catalog must use schemaVersion 2")

    script_points = load_index(RESOURCES / "ScriptPoints", "scriptPointID")
    prerecordings = load_index(RESOURCES / "Prerecordings", "prerecordingID")
    voice_prompts = load_index(RESOURCES / "VoicePrompts", "voicePromptID")
    fixed = {"dadFrame": "rich", "crankRadio": "broadcaster", "walkie": "big_mike"}
    ham_allowed = {"dad", "cateye81"}
    episode_ids: set[str] = set()
    moment_ids: set[str] = set()
    identity_keys: set[tuple[str, str]] = set()

    for episode in catalog.get("episodes", []):
        episode_id = episode["episodeID"]
        if episode_id in episode_ids:
            fail(f"duplicate episode: {episode_id}")
        episode_ids.add(episode_id)
        segment_ids = {segment["segmentID"] for segment in episode.get("segments", [])}
        ordinals: set[int] = set()
        moments = episode.get("moments", [])

        for moment in moments:
            moment_id = moment["momentID"]
            if moment_id in moment_ids:
                fail(f"duplicate moment: {moment_id}")
            moment_ids.add(moment_id)
            identity = (moment["scriptPointID"], moment["authoredPrerecordingID"])
            if identity in identity_keys:
                fail(f"duplicate authored identity: {identity}")
            identity_keys.add(identity)
            if moment["segmentID"] not in segment_ids:
                fail(f"unknown segment for {moment_id}")
            ordinal = moment["narrativeOrdinal"]
            if ordinal in ordinals:
                fail(f"duplicate narrative ordinal in {episode_id}: {ordinal}")
            ordinals.add(ordinal)

            surface = moment["interactionSurface"]
            target = moment["conversationTargetCharacterID"]
            if surface in fixed and target != fixed[surface]:
                fail(f"{moment_id} targets {target}; {surface} requires {fixed[surface]}")
            if surface == "hamReceiver" and target not in ham_allowed:
                fail(f"{moment_id} has invalid ham partner {target}")

            script_point = script_points.get(moment["scriptPointID"])
            recording = prerecordings.get(moment["authoredPrerecordingID"])
            if script_point is None or recording is None:
                fail(f"missing ScriptPoint or PR resource for {moment_id}")
            transmission = script_point["transmission"]
            if transmission.get("characterID") != moment["speakerCharacterID"]:
                fail(f"ScriptPoint speaker mismatch for {moment_id}")
            if recording.get("speaker") != moment["speakerCharacterID"]:
                fail(f"PR speaker mismatch for {moment_id}")
            if effective_surface(transmission) != surface:
                fail(f"surface mismatch for {moment_id}")

            candidates = sorted(
                (
                    candidate
                    for candidate in moments
                    if candidate["interactionSurface"] == surface
                    and candidate["speakerCharacterID"] == target
                ),
                key=lambda candidate: candidate["narrativeOrdinal"],
            )
            prior = [
                candidate
                for candidate in candidates
                if candidate["narrativeOrdinal"] <= ordinal
            ]
            selected = prior[-1] if prior else next(
                (
                    candidate
                    for candidate in candidates
                    if candidate["narrativeOrdinal"] > ordinal
                ),
                None,
            )
            if selected is None:
                fail(f"no target PromptVoice context for {moment_id}")
            target_script = script_points[selected["scriptPointID"]]
            prompt_id = resolve_voice_prompt_id(selected, target_script)
            prompt = voice_prompts.get(prompt_id)
            if prompt is None or prompt.get("speakerID") != target:
                fail(f"target VoicePrompt speaker mismatch for {moment_id}")

        for checkpoint in episode.get("checkpoints", []):
            if checkpoint["segmentID"] not in segment_ids:
                fail(f"checkpoint references unknown segment in {episode_id}")


def require_source_contracts() -> None:
    source = "\n".join(path.read_text() for path in APP.rglob("*.swift"))
    if "actor TuringLiveConversationSeedRegistry" in source:
        fail("a second authoritative microphone registry remains")
    if re.search(r"targetCharacterID\s*=\s*.*transmission\.characterID", source):
        fail("conversation target is still derived from the current PR speaker")

    coordinator = (
        APP / "Turing/Conversation/TuringLiveConversationSessionCoordinator.swift"
    ).read_text()
    if "pre-filler did not latch microphone" not in coordinator:
        fail("PR queue/pre-filler path can still activate a microphone")
    if "case .authoredMediaStarted" not in coordinator:
        fail("actual authored playback start is not the activation event")

    arbiter = (APP / "Story/Interaction/StoryInteractionArbiter.swift").read_text()
    for marker in (
        "latchedMicrophoneSlots",
        "microphoneGeneration",
        "latchConversationMicrophone",
        "replaceConversationMicrophonesForContinue",
        "clearConversationMicrophonesState",
    ):
        if marker not in arbiter:
            fail(f"arbiter is missing {marker}")
    if arbiter.count("clearConversationMicrophonesState(") < 4:
        fail("chapter/battle/reset microphone invalidation is incomplete")

    seed_source = (
        APP / "Turing/Conversation/TuringLiveConversationSeed.swift"
    ).read_text()
    if "priorTargetTranscript = nil" not in seed_source:
        fail("next target selection can inject a future target PR transcript")

    chapter01 = (
        APP / "Story/Chapter/Chapter01/Chapter01Coordinator.swift"
    ).read_text()
    if "antigenDroneSequence" not in chapter01:
        fail("Chapter 1 Robot/antigen boundary does not clear microphones")

    for name in (
        "Walkie",
        "DadFrame",
        "CrankRadio",
        "HamReceiver",
    ):
        controller = (
            APP / f"Turing/Interaction/TuringStory{name}InteractionController.swift"
        ).read_text()
        if "currentLatchedConversationSeed" not in controller:
            fail(f"{name} selection does not use the latched slot")
        if "binding.conversationCharacterID" in controller:
            fail(f"{name} still routes live speech from its static binding")

    placeholders = {
        "{{immediateDeviceTranscript}}",
        "{{immediateDeviceSpeakerID}}",
        "{{targetPriorTranscript}}",
        "{{targetContextPosition}}",
    }
    for path in sorted((RESOURCES / "Prompts").glob("conversationPrompt_*.txt")):
        if path.name not in {
            "conversationPrompt_playerTurn_noBible.txt",
            "conversationPrompt_scriptPoint05.txt",
            "conversationPrompt_roomObjectMemory.txt",
            "conversationPrompt_broadcasterRadio.txt",
            "conversationPrompt_cateye81HamReceiver.txt",
        }:
            continue
        prompt = path.read_text()
        missing = {placeholder for placeholder in placeholders if placeholder not in prompt}
        if missing:
            fail(f"{path.name} lacks split context placeholders: {sorted(missing)}")


def main() -> None:
    validate_catalog()
    require_source_contracts()
    print("deterministic microphone routing: PASS")


if __name__ == "__main__":
    main()
