#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Gravitas Plague/Gravitas Plague"
RESOURCES = ROOT / "Gravitas Plague/TuringResources/Turing"
CHAPTER = APP / "Story/Chapter/Chapter03"

EXPECTED_MEDIA_HASHES = {
    "biker-battle-music.mp3": "1897443ece8e9aaa17c7e645ad2e8f3f3f6c4ef1e020f23ada0cc7889bae9b6d",
    "big-mike-battle-01-music.mp3": "03d1bdb3e97b982596c427c8e54e354dbd4df4c9fa4fda68ca5ddcf377273ab0",
    "big-mike-battle-02-music.mp3": "e39bc3a1ad4b1a09203cd2496869c1831455de9ec932ea89f1be887072a17d3e",
}


def fail(message: str) -> None:
    print(f"chapter03 production verifier: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_in_order(source: str, markers: list[str], label: str) -> None:
    cursor = -1
    for marker in markers:
        found = source.find(marker, cursor + 1)
        if found == -1:
            fail(f"{label} is missing ordered marker: {marker}")
        cursor = found


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(relative_path: str) -> dict:
    path = RESOURCES / relative_path
    if not path.is_file():
        fail(f"missing resource: {relative_path}")
    return json.loads(path.read_text())


def main() -> None:
    biker = load_json("Battles/Chapter03BikerBattle/chapter03_biker_battle.json")
    mike = load_json("Battles/Chapter03MikeBattle/chapter03_mike_battle.json")

    if biker["playerConfirmedHitsToKill"] != 10 or mike["playerConfirmedHitsToKill"] != 10:
        fail("both Chapter 3 battles must require ten confirmed enemy hits to kill Rich")
    music = biker["music"] + mike["music"]
    if [item["gainDB"] for item in music] != [-7.0, -7.0, -7.0]:
        fail("the three Chapter 3 battle songs must be authored at -7 dB")
    if any(item["loop"] for item in music):
        fail("Chapter 3 battle songs must remain one-shot")
    if mike["enemy"]["acceptedCapacityNumerator"] != 4 or mike["enemy"]["acceptedCapacityDenominator"] != 3:
        fail("Mike must require ceiling(Dad-equivalent hits times 4/3)")
    if mike["postSurrenderPrerecordingBeatSeconds"] != 1.0:
        fail("Mike surrender must retain the authored one-second post-PR beat")

    audio_root = RESOURCES / "Audio/chapter03"
    for filename, expected in EXPECTED_MEDIA_HASHES.items():
        path = audio_root / filename
        if not path.is_file() or sha256(path) != expected:
            fail(f"Chapter 3 battle music missing or changed: {filename}")

    battle_sources = "\n".join(
        path.read_text()
        for path in CHAPTER.glob("Chapter03*Battle*.swift")
    )
    for forbidden in (
        "LanguageModelSession",
        "TuringCharacterQwen",
        "conversationVoice",
        "voicePromptID",
        "doorFullyOpen",
        "hitsToKill + 1",
    ):
        if forbidden in battle_sources:
            fail(f"forbidden battle implementation found: {forbidden}")

    mike_source = (CHAPTER / "Chapter03MikeBattleCoordinator.swift").read_text()
    require_in_order(
        mike_source,
        [
            "enqueueAndWait(surrenderCue)",
            "postSurrenderPrerecordingBeatSeconds",
            "fadeToFullBlack(",
            "requireFullBlackOwnership(requestID: transitionID)",
            "combat?.releaseUnderFullBlack",
            "closeForBattleAndUnloadPortal(",
            "cleanup.releaseBattle(",
            "roomPresentation.suppressUnderFullBlack(",
            "transferBattleToStoryTransition(",
            "guard releaseEvent.isSafeForHeaven",
            "chapter03MikeBattleReleased(",
        ],
        "Mike PR-completion to Heaven boundary",
    )
    if "event.cueID == \"mikeSurrender\"" not in mike_source:
        fail("Mike music-two crossfade is not keyed to surrender PR actual playback")
    if "triggerEventID: event.playbackID" not in mike_source:
        fail("Mike music-two crossfade is not keyed to the actual PR playback ID")

    coordinator = (CHAPTER / "Chapter03Coordinator.swift").read_text()
    require_in_order(
        coordinator,
        [
            "func chapter03MikeBattleReleased(",
            ".heavenTransitionPending",
            "startLightTunnel(",
            "lightTunnel.start(",
        ],
        "released Mike to existing tunnel handoff",
    )
    if "Chapter03LightTunnelCoordinator" not in coordinator:
        fail("production Chapter 3 does not reuse the established Heaven tunnel")
    if "Heaven tunnel preflight completed" not in coordinator:
        fail("production Chapter 3 does not preflight Heaven resources before Mike")
    if "heavyVisualsLoaded=false" not in coordinator:
        fail("Chapter 3 tunnel preflight must leave heavy visuals deferred")
    terminal_handoff = coordinator.split("private func lightTunnelCompleted", 1)[1]
    terminal_handoff = terminal_handoff.split("private func lightTunnelFailed", 1)[0]
    if "requestID: event.blackoutRequestID" not in terminal_handoff:
        fail("terminal title card does not inherit the full-black ownership ID")
    if "requestID: event.chapterRunID" in terminal_handoff:
        fail("terminal title card incorrectly reuses the Chapter run ID")
    if "titleTransitionID=\\(event.blackoutRequestID.uuidString)" not in terminal_handoff:
        fail("terminal full-black ownership transfer is not logged")
    continuation_store = (
        ROOT / "Gravitas Plague/Gravitas Plague/Turing/Story/"
        "TuringStoryProgressStore.swift"
    ).read_text()
    continuation_picker = (
        ROOT / "Gravitas Plague/Gravitas Plague/Turing/Story/"
        "TuringStoryEpisodePickerView.swift"
    ).read_text()
    if "var titleCardDestination: StoryTitleCardDestination" not in continuation_store:
        fail("Chapter 3 terminal continuation has no destination override")
    if "return .endOfAvailableContent(completedEpisode: .chapter03)" not in continuation_store:
        fail("Chapter 3 end-card checkpoint does not resume as terminal content")
    if "destination: target.titleCardDestination" not in continuation_picker:
        fail("episode picker bypasses the terminal continuation destination")
    if "unsafeReasons" not in mike_source:
        fail("Mike-to-Heaven release still reports only an opaque safety failure")

    definition_store = (
        CHAPTER / "LightTunnel/Chapter03LightTunnelDefinitionStore.swift"
    ).read_text()
    if "heaven-sunrise" not in definition_store or "angel_posed_01" not in definition_store:
        fail("tunnel preflight does not validate both heavy visual resource URLs")

    progress_store = (CHAPTER / "Chapter03ProgressStore.swift").read_text()
    if 'value.contentRevision == "chapter03.lightTunnelTest.v2"' not in progress_store:
        fail("legacy tunnel-only progress revision is not explicitly recognized")
    if "checkpoint: .root" not in progress_store:
        fail("legacy tunnel-only progress can skip the production Chapter 3 opening")

    jock = (APP / "JockRetargetTestController.swift").read_text()
    require_in_order(
        jock,
        [
            "case headSnapAndImpactOnly",
            "headSnapClipID = triggerHeadSnapSubAnimation",
            "== .headSnapAndImpactOnly",
            "damageApplied=false fullBodyReaction=false",
            "interceptedAsNonlethalDefeat",
            "let shouldDie",
            "if shouldDie",
            "onStoryNonlethalDefeatThresholdReached?(snapshot)",
        ],
        "Jock nonlethal terminal-hit interception",
    )
    if "setIncomingPlayerPunchDetectionEnabled(false)" in jock:
        fail("Mike terminal defeat disables punch detection instead of damage only")

    combat_adapter = (CHAPTER / "Chapter03BattleCombatAdapters.swift").read_text()
    if "postDefeatMode ? .headSnapAndImpactOnly : .applyDamage" not in combat_adapter:
        fail("Mike post-defeat punches do not preserve head snap and impact without damage")

    room = (CHAPTER / "Chapter03RoomPresentationController.swift").read_text()
    require_in_order(
        room,
        [
            "requireFullBlackOwnership(requestID: transitionID)",
            "let before = try fingerprintProvider()",
            "suspendPresentationForCinematic(",
            "root.isEnabled = false",
        ],
        "full-black room suppression",
    )

    catalog = (APP / "Turing/Story/TuringEpisodeCatalog.swift").read_text()
    if "id: .chapter03" not in catalog or "productionPickerEpisodes = productionEpisodes" not in catalog:
        fail("Chapter 3 is not a production episode and picker destination")

    script_points = sorted((RESOURCES / "ScriptPoints").glob("chapter03.*.json"))
    voice_prompts = sorted((RESOURCES / "VoicePrompts").glob("chapter03.*.json"))
    prerecordings = sorted((RESOURCES / "Prerecordings").glob("chapter03.*.json"))
    if len(script_points) != 6 or len(voice_prompts) != 6 or len(prerecordings) != 9:
        fail(
            "Chapter 3 requires six ScriptPoints, six PromptVoice descriptors, "
            "and nine prerecording descriptors"
        )
    for descriptor_path in prerecordings:
        descriptor = json.loads(descriptor_path.read_text())
        filename = descriptor["audioFile"]
        installed = RESOURCES / "Audio/prerecordings" / filename
        source = ROOT / filename
        if not installed.is_file():
            fail(
                f"Chapter 3 prerecording is not installed in the shared "
                f"TuringPrerecordingStore directory: {filename}"
            )
        if not source.is_file() or sha256(installed) != sha256(source):
            fail(f"Chapter 3 prerecording was not installed byte-for-byte: {filename}")
    for path in script_points:
        descriptor = json.loads(path.read_text())
        transmission = descriptor["transmission"]
        if transmission["computeStart"] != "foundationBeforePrerecording":
            fail(f"PR started before fresh Foundation acceptance: {path.name}")

    print("chapter03 production verifier: PASS")


if __name__ == "__main__":
    main()
