#!/usr/bin/env python3
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Gravitas Plague/Gravitas Plague"


def fail(message: str) -> None:
    print(f"PR/battle audio verifier: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(source: str, marker: str, label: str) -> None:
    if marker not in source:
        fail(f"{label} missing: {marker}")


def require_in_order(source: str, markers: tuple[str, ...], label: str) -> None:
    cursor = -1
    for marker in markers:
        cursor = source.find(marker, cursor + 1)
        if cursor < 0:
            fail(f"{label} missing ordered marker: {marker}")


def main() -> None:
    timing = (APP / "Turing/Audio/TuringPrerecordingOrientationTiming.swift").read_text()
    require(timing, "Double.random(in: 2.0...5.0)", "orientation duration")
    require(timing, "chapter02.room.rich.windowRecognition.001", "window exclusion")
    require(timing, "chapter02.room.rich.womanBattle.001", "woman battle exclusion")
    require(timing, "role == .primaryPrerecording || role == .authoredBridge", "media-role gate")

    battle_source = "\n".join(
        path.read_text() for path in (APP / "Battle").rglob("*.swift")
    )
    if "TuringPrerecordingOrientationCoordinator" in battle_source:
        fail("orientation coordinator is reachable from the Battle directory")

    excluded_paths = [
        APP / "Story/Chapter/Chapter01/DadFinalBattle/StoryBattleRichPrerecordingQueue.swift",
        APP / "Story/Chapter/Chapter02/Chapter02PrerecordingPlayer.swift",
        APP / "Story/Chapter/Chapter03/Chapter03BikerBattleCoordinator.swift",
        APP / "Story/Chapter/Chapter03/Chapter03MikeBattleCoordinator.swift",
    ]
    for path in excluded_paths:
        if "TuringPrerecordingOrientationCoordinator" in path.read_text():
            fail(f"battle/cinematic path invokes orientation: {path.name}")

    queue = excluded_paths[0].read_text()
    require_in_order(
        queue,
        ("guard player.play()", "beginBattleSpeech("),
        "battle PR actual-start suppression",
    )
    require(queue, "endBattleSpeech(", "battle PR suppression release")

    chapter02 = excluded_paths[1].read_text()
    require_in_order(
        chapter02,
        ("case .started(let returned) where returned == handle", "beginBattleSpeech("),
        "Chapter 2 exact-start suppression",
    )
    require(chapter02, "endBattleSpeech(", "Chapter 2 suppression release")

    coordinators = (
        APP / "Battle/Battle01/Battle01Coordinator.swift",
        APP / "Story/Chapter/Chapter01/DadFinalBattle/Chapter01DadFinalBattleCoordinator.swift",
        APP / "Story/Chapter/Chapter02/Chapter02WomanBattleCoordinator.swift",
        APP / "Story/Chapter/Chapter03/Chapter03BikerBattleCoordinator.swift",
        APP / "Story/Chapter/Chapter03/Chapter03MikeBattleCoordinator.swift",
    )
    for path in coordinators:
        require(path.read_text(), "richVocalChannel", f"Rich vocal injection in {path.name}")

    audio = (APP / "GravitasDemoAudioController.swift").read_text()
    require(audio, "activeBattleSpeechTokens.isEmpty == false", "damage-vocal suppression")
    require(audio, "activePlayerDeathVocal != nil", "death-vocal suppression")
    require(audio, "purpose: .actualPlayerDeath", "typed actual-death compatibility")

    mike = excluded_paths[3].read_text()
    require_in_order(
        mike,
        (
            "enqueueAndWait(surrenderCue)",
            "startRandomPlayerDeathVocal(",
            "postSurrenderPrerecordingBeatSeconds",
            "finishAfterSurrender(",
        ),
        "Mike PR-to-Heaven death bridge",
    )
    surrender_tail = mike.split("enqueueAndWait(surrenderCue)", 1)[1]
    if "playRandomPlayerDeathAndReturnDuration" in surrender_tail:
        fail("Mike bridge routes through legacy duration-based actual-death playback")
    if "Task.sleep" in surrender_tail.split("finishAfterSurrender(", 1)[0]:
        fail("Mike bridge waits directly on a death-vocal duration")
    for forbidden in ("YouDied", "youDied", "presentPlayerDeath"):
        if forbidden in surrender_tail:
            fail(f"Mike-to-Heaven bridge invokes actual death UI: {forbidden}")

    print(
        "PR/battle audio verifier: OK orientation=2...5s battleOwners=5 "
        "deathBridge=nonblocking"
    )


if __name__ == "__main__":
    main()
