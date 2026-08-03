#!/usr/bin/env python3
from pathlib import Path
import sys


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
APP = ROOT / "Gravitas Plague" / "Gravitas Plague"


def read(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"missing required file: {path}")
    return path.read_text(encoding="utf-8")


catalog = read(APP / "Story/TitleCards/StoryTitleCardCatalog.swift")
picker = read(APP / "Turing/Story/TuringStoryEpisodePickerView.swift")
factory = read(APP / "Story/TitleCards/StoryTitleCardTextFactory.swift")
transition = read(APP / "Story/TitleCards/StoryTitleCardTransitionCoordinator.swift")
chapter = read(APP / "Story/Chapter/Chapter01/Chapter01Coordinator.swift")
resource = read(
    ROOT
    / "Gravitas Plague/TuringResources/Turing/ScriptPoints"
    / "chapter01.dadFrame.rich.script03.json"
)

required_catalog_text = (
    'title: "Prologue"',
    'subtitle: "They are not human they are monsters"',
    'title: "Chapter 1"',
    'subtitle: "Dad?"',
    'title: "Gravitas Plague"',
)
for needle in required_catalog_text:
    if needle not in catalog:
        raise SystemExit(f"missing title-card contract: {needle}")

if "MeshResource.generateText" not in factory or "UnlitMaterial" not in factory:
    raise SystemExit("title cards must use procedural unlit RealityKit text")
if "TextureResource" in factory or "InputTargetComponent()" in factory:
    raise SystemExit("title cards cannot be textured or interactive")
if "requireValidContinuationTarget" not in picker:
    raise SystemExit("Continue must freeze the validated continuation target")
if "menuMusicPolicy: .playThroughCard" not in picker:
    raise SystemExit("Continue must keep main-menu music through the title card")
fade_complete = transition.index("try await blackout.fadeBackUp(")
music_stop = transition.index('reason: "titleCardBlackoutFullyFaded.')
if music_stop < fade_complete:
    raise SystemExit("Continue music must stop only after blackout fully fades")
if '"interactionGateAfterCompletion": "closed"' not in resource:
    raise SystemExit("final Dad frame must not flash a microphone")
if "StoryEpisodeBoundaryEvent(" not in chapter or "state = .complete" in chapter:
    raise SystemExit("Chapter 1 must terminate through the title-card boundary")

print("Story title-card static verification passed.")
