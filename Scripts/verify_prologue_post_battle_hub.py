#!/usr/bin/env python3
"""Static ownership checks for the Prologue post-battle four-device hub."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Gravitas Plague" / "Gravitas Plague"
INTERACTION = APP / "Turing" / "Interaction"
STORY = APP / "Turing" / "Story"
BATTLE = APP / "Battle" / "Battle01"


def swift_texts(directory: Path) -> list[tuple[Path, str]]:
    return [(path, path.read_text()) for path in sorted(directory.rglob("*.swift"))]


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def main() -> int:
    battle = swift_texts(BATTLE)
    interaction = swift_texts(INTERACTION)
    story = swift_texts(STORY)

    for path, text in battle:
        if re.search(r"ProloguePostBattleDevice|postBattle.*Device", text, re.I):
            fail(f"Battle01 owns post-battle device progression: {path}")

    for path, text in interaction:
        if "UserDefaults" in text:
            fail(f"interaction controller writes persistence directly: {path}")

    installation_methods = {
        "TuringStoryWalkieInteractionController.swift": "walkieInstalled",
        "TuringStoryDadFrameInteractionController.swift": "dadFrameInstalled",
        "TuringStoryCrankRadioInteractionController.swift": "crankRadioInstalled",
        "TuringStoryHamReceiverInteractionController.swift": "hamReceiverInstalled",
    }
    for filename, method in installation_methods.items():
        text = (INTERACTION / filename).read_text()
        match = re.search(
            rf"func\s+{re.escape(method)}\b(?P<body>.*?)(?=\n\s*func\s|\n\s*private\s+func\s|\Z)",
            text,
            re.S,
        )
        require(match is not None, f"missing installation method {method}")
        if re.search(r"\barmPlay\s*\(", match.group("body")):
            fail(f"{filename}.{method} auto-arms Play during installation")

    progress_owners = [
        path
        for path, text in story
        if re.search(r"\b(actor|class)\s+TuringProloguePostBattleProgressStore\b", text)
    ]
    require(
        len(progress_owners) == 1,
        f"expected one post-battle progress owner, found {len(progress_owners)}",
    )

    store = (STORY / "TuringProloguePostBattleProgressStore.swift").read_text()
    require(
        '"turing.story.prologue.postBattleHub.snapshot.v2"' in store,
        "schema-v2 atomic save key is missing",
    )
    for forbidden in ("FoundationModels", "Qwen", "promptContext", "storyIntent"):
        if forbidden in store:
            fail(f"progress store contains prompt/model data: {forbidden}")

    coordinator = (STORY / "TuringPrologueCompletionCoordinator.swift").read_text()
    complete_index = coordinator.find("postBattleProgress.completeDevice")
    title_index = coordinator.find("publishEpisodeBoundary")
    require(complete_index >= 0, "device completion transaction is missing")
    require(title_index > complete_index, "title request appears before durable completion")
    require(
        "transaction.snapshot.allDevicesCompleted" in coordinator,
        "Chapter boundary lacks an explicit all-four durable-state guard",
    )

    picker = (STORY / "TuringStoryEpisodePickerView.swift").read_text()
    require(
        "chapterTransitionPending" in picker and ".chapter01" in picker,
        "Continue does not route a pending boundary directly to Chapter 1",
    )

    print("PASS: Prologue post-battle hub static ownership checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
