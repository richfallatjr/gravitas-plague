#!/usr/bin/env python3
import hashlib
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "Gravitas Plague" / "TuringResources" / "Turing"
SOURCE_ROOT = (
    ROOT
    / "Gravitas Plague"
    / "Gravitas Plague"
    / "Story"
    / "Chapter"
    / "Chapter01"
)

EXPECTED_AUDIO = {
    "pr-rich-dad-window-01.mp3": "8277ca5dcfad5fb74e05dba57ebd5979ddc30040f804e9d0e23ebfa3c74ebd53",
    "pr-robot-scan-instruction.mp3": "712ad90844604c54c34ceb447d4dc27b1da46d308e72549743712c3b9ef808bd",
    "pr-robot-compliance-warning.mp3": "7ff810f3f2544ebad04d26ed0ad1c95b1feebfa537d14906099d56b621a63a72",
    "pr-robot-compliance-restored.mp3": "357e509a25069d25fbe28492f050cb1dbb0ca987b987d5efb20505e37f8ed50c",
    "pr-robot-successful-scan.mp3": "4ff8221805a796b258ae8cba9469b2a99f3949ae99d5d05ba12812e17889d73a",
    "pr-robot-payload-release.mp3": "bdc6f8636c495a3291f46b3761e8dce484f80100820168c2f8f455e093de3edb",
    "pr-robot-exit-confirmation.mp3": "67a011bda4f9fb2664ac7caf29c4c4758bec3add4c37d07adc6d99e6e954c370",
}

EXPECTED_CUES = {
    "scanInstruction": "pr-robot-scan-instruction.mp3",
    "complianceWarning": "pr-robot-compliance-warning.mp3",
    "complianceRestored": "pr-robot-compliance-restored.mp3",
    "successfulScan": "pr-robot-successful-scan.mp3",
    "payloadRelease": "pr-robot-payload-release.mp3",
    "exitConfirmation": "pr-robot-exit-confirmation.mp3",
}

EXPECTED_TRANSCRIPTS = {
    "scanInstruction": "Please remain still. This unit is operating on behalf of the Gravitas Corporation. A brief diagnostic scan is required. Face forward, and keep your head as still as possible.",
    "complianceWarning": "Movement detected. This is your final compliance warning. Continued resistance will be interpreted as late-stage infection and loss of behavioral control. Remain still, or defensive measures will be authorized.",
    "complianceRestored": "Compliance restored. Scanning in progress. Keep your head facing forward until confirmation.",
    "successfulScan": "Diagnostic scan complete. No late-stage behavioral markers detected. One Gravitas antigen pack has been authorized. Antigen is effective only during early-stage infection. It may temporarily suppress progression. It is not a cure. Payload transfer complete.",
    "payloadRelease": "Critical unit failure. Delivery protocol interrupted. Emergency payload release authorized. One antigen pack has been released for recovery. Antigen is intended for early-stage infection only.",
    "exitConfirmation": "Delivery confirmed. Remain indoors and monitor authorized frequencies for further instructions. This unit is returning to relay operations.",
}

EXPECTED_MUSIC = {
    "dad-window-music.mp3": "e91df69710a9d3213bce353a45fa5bdc0ea7b9bc5d7ecac2469a88e87e67d13d",
    "robot-beserk-music.mp3": "7e50ecf89185a050e605df10686a0533b072e49832a1ad0c790d564bdb523c18",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    definition_path = RESOURCE_ROOT / "Story" / "Chapter01" / "chapter01.gravitasRobot.001.json"
    speech_path = RESOURCE_ROOT / "Story" / "Chapter01" / "chapter01.robot.speech.json"
    definition = json.loads(definition_path.read_text())
    speech = json.loads(speech_path.read_text())

    if definition["encounterID"] != "chapter01.encounter.gravitasRobot.001":
        fail("encounter ID changed")
    if definition["combat"] != {
        "incomingPlayerHitAcceptanceProbability": 0.1,
        "acceptedPlayerHitsToDestroyMinimum": 30,
        "acceptedPlayerHitsToDestroyMaximum": 40,
        "confirmedRobotHitsToKillPlayer": 5,
    }:
        fail("Robot combat contract changed")
    if speech["speakerID"] != "gravitas_robot" or speech["outputRoute"] != "storyRobotSpatial":
        fail("Robot speech authority or route changed")
    if len(speech["cues"]) != 6 or len({cue["cueID"] for cue in speech["cues"]}) != 6:
        fail("Robot speech catalog must contain six unique cues")
    actual_cues = {cue["cueID"]: cue["audioFile"] for cue in speech["cues"]}
    if actual_cues != EXPECTED_CUES:
        fail(f"Robot speech cue mapping changed: {actual_cues}")
    actual_transcripts = {cue["cueID"]: cue["transcript"] for cue in speech["cues"]}
    if actual_transcripts != EXPECTED_TRANSCRIPTS:
        fail("Robot speech transcript sidecars changed")

    audio_root = RESOURCE_ROOT / "Audio" / "prerecordings"
    for filename, expected_hash in EXPECTED_AUDIO.items():
        path = audio_root / filename
        if not path.is_file() or path.stat().st_size == 0:
            fail(f"missing authored Robot PR: {filename}")
        actual = sha256(path)
        if actual != expected_hash:
            fail(f"Robot PR hash mismatch: {filename} {actual}")

    music_catalog_path = RESOURCE_ROOT / "Story" / "Chapter01" / "chapter01.music.json"
    music_catalog = json.loads(music_catalog_path.read_text())
    expected_music_paths = {
        "dadWindow": "Turing/Audio/chapter01/dad-window-music.mp3",
        "robotAttack": "Turing/Audio/chapter01/robot-beserk-music.mp3",
    }
    actual_music_paths = {
        cue["cueID"]: cue["resourcePath"] for cue in music_catalog["cues"]
    }
    if actual_music_paths != expected_music_paths:
        fail(f"Chapter music cue mapping changed: {actual_music_paths}")
    music_root = RESOURCE_ROOT / "Audio" / "chapter01"
    for filename, expected_hash in EXPECTED_MUSIC.items():
        path = music_root / filename
        if not path.is_file() or sha256(path) != expected_hash:
            fail(f"Chapter music missing or changed: {filename}")

    chapter_source = "\n".join(path.read_text() for path in SOURCE_ROOT.glob("*.swift"))
    for forbidden in ("FoundationModels", "LanguageModelSession", "TuringQwen", "promptVoice", "conversationVoice"):
        if forbidden in chapter_source:
            fail(f"Robot Chapter source must not invoke generated speech: {forbidden}")

    dad_runtime_source = (SOURCE_ROOT / "Chapter01DadRuntime.swift").read_text()
    robot_factory_source = (SOURCE_ROOT / "Chapter01RobotFactory.swift").read_text()
    for source_name, source in (
        ("Dad runtime", dad_runtime_source),
        ("Robot factory", robot_factory_source),
    ):
        if "setScriptedVisualHeadingOffsetDegrees" in source:
            fail(f"{source_name} must use the shared rig heading correction exactly once")

    robot_coordinator_source = (
        SOURCE_ROOT / "Chapter01RobotEncounterCoordinator.swift"
    ).read_text()
    controller_tick = robot_coordinator_source.find("runtime?.controller.update(")
    path_tick = robot_coordinator_source.find("pathFollower.update(deltaTime: deltaTime)")
    if controller_tick == -1 or path_tick == -1 or controller_tick > path_tick:
        fail("Robot animation driver must update before scripted path locomotion")

    dad_pr_source = (
        SOURCE_ROOT / "Chapter01DadWindowPrerecordingController.swift"
    ).read_text()
    if "pr-rich-dad-window-01.mp3" not in dad_pr_source:
        fail("Dad-window Rich prerecording resource contract is missing")
    if "desiredCompletionAfterExitWalkStartSeconds: TimeInterval = 2" not in dad_pr_source:
        fail("Dad-window Rich prerecording must finish two seconds into the exit walk")
    if "audioDurationSeconds" not in dad_pr_source or "exitTurnDurationSeconds" not in dad_pr_source:
        fail("Dad-window Rich prerecording start must be derived from timeline durations")

    antigen_descriptor = RESOURCE_ROOT / "Story" / "Chapter01" / "chapter01.antigenReward.001.json"
    if not antigen_descriptor.is_file():
        fail("authored antigen reward descriptor is missing")
    antigen = json.loads(antigen_descriptor.read_text())
    if antigen.get("modelKind") != "authoredBundleGroup":
        fail("antigen reward must reuse the authored rolling-cart group")
    if antigen.get("modelResourcePath") is not None:
        fail("authored antigen reward must not load a second model resource")
    if antigen.get("rollingCartAnchorName") != "antigen_anchor_root":
        fail("authored antigen reward anchor changed")
    expected_antigen_entities = [
        "antigen_holster_root",
        "antigen_vile_01_root",
        "antigen_vile_02_root",
        "antigen_vile_03_root",
        "antigen_vile_04_root",
    ]
    if antigen.get("authoredEntityNames") != expected_antigen_entities:
        fail("authored antigen package membership changed")

    rolling_bench_source = (
        ROOT
        / "Gravitas Plague"
        / "Gravitas Plague"
        / "Turing"
        / "Props"
        / "TuringRollingBenchBundleController.swift"
    ).read_text()
    if "preservingWorldTransform: true" not in rolling_bench_source:
        fail("authored antigen members must preserve their USDZ transforms")
    if "anchor.isEnabled = false" not in rolling_bench_source:
        fail("authored antigen package must remain hidden before reward")

    reward_presenter_source = (
        ROOT
        / "Gravitas Plague"
        / "Gravitas Plague"
        / "Story"
        / "HUD"
        / "StoryItemRewardPresenter.swift"
    ).read_text()
    if ".generateBox" in reward_presenter_source or "proceduralCube" in reward_presenter_source:
        fail("temporary procedural antigen presentation remains active")
    print("Authored rolling-cart antigen reward verified.")

    print("Chapter01 Robot encounter verification passed.")


if __name__ == "__main__":
    main()
