#!/usr/bin/env python3
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CHAPTER = ROOT / "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03"
CATALOG = ROOT / "Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodeCatalog.swift"
DEFINITION = ROOT / (
    "Gravitas Plague/TuringResources/Turing/Chapters/Chapter03/"
    "chapter03_light_tunnel_test.json"
)
MUSIC = ROOT / (
    "Gravitas Plague/TuringResources/Turing/Audio/chapter03/"
    "chapter03-light-at-the-end-of-the-tunnel.mp3"
)
PICKER_ART = ROOT / (
    "Gravitas Plague/Gravitas Plague/Assets.xcassets/"
    "episode-chapter-3-button.imageset/episode-chapter-3-button.png"
)
ANGEL = ROOT / "angel_biped.usdz"
HEAVEN = ROOT / "heaven-sunrise.exr"


def fail(message: str) -> None:
    print(f"chapter03 verifier: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


sources = "\n".join(path.read_text() for path in CHAPTER.rglob("*.swift"))
for forbidden in (
    "LanguageModelSession",
    "TuringCharacterQwen",
    "SpeechDecoder",
    "voicePromptID",
    "headAnchor",
    "HeadTracked",
    "scanRoom",
    "requestRoomScan",
    "requestPlacement",
    "YouDiedWorldCardPresenter",
    "playDeathBlackoutSequence",
):
    if forbidden in sources:
        fail(f"forbidden Chapter 3 dependency found: {forbidden}")

if "Task.sleep(trackDuration" in sources or "metadataDurationCompleted" in sources:
    fail("music completion may not be duration-estimated")

catalog = CATALOG.read_text()
match = re.search(
    r"productionEpisodes:\s*\[TuringEpisodeDescriptor\]\s*=\s*\[(.*?)\n\s*\]",
    catalog,
    re.S,
)
if not match:
    fail("could not inspect production episode catalog")
if "id: .chapter03" in match.group(1):
    fail("Chapter 3 must not alter the Chapter 2 production progression boundary")
if "productionPickerEpisodes" not in catalog or "chapter03PickerEpisode" not in catalog:
    fail("Chapter 3 direct picker entry is missing")
if not PICKER_ART.is_file() or PICKER_ART.stat().st_size == 0:
    fail("Chapter 3 picker strip artwork is missing or empty")
if not ANGEL.is_file() or ANGEL.stat().st_size == 0:
    fail("Chapter 3 angel USDZ is missing or empty")
if not HEAVEN.is_file() or HEAVEN.stat().st_size == 0:
    fail("Chapter 3 heaven EXR is missing or empty")
if "Chapter03AngelPortalEntity.load" not in sources:
    fail("Chapter 3 presenter does not install the static portal angel")
if "angel_float_pose_01" not in sources:
    fail("Chapter 3 static angel does not use the authored floating pose")
for forbidden_visual in (
    "FrameRecord",
    "makeBar",
    "generateBox",
    "Chapter03FinalRadianceWash",
    "maximumFinalWashOpacity",
    "ringCount",
):
    if forbidden_visual in sources:
        fail(f"invented rectangular tunnel visual remains: {forbidden_visual}")
for required_visual in (
    "PortalComponent",
    "PortalMaterial",
    "WorldComponent",
    "Chapter03CircularPortalAperture",
    "heaven-sunrise",
):
    if required_visual not in sources:
        fail(f"required circular portal contract is missing: {required_visual}")

definition = json.loads(DEFINITION.read_text())
if not MUSIC.is_file() or MUSIC.stat().st_size == 0:
    fail("canonical Chapter 3 music is missing or empty")
if definition.get("angelPrerecording", "missing") is not None:
    fail("Angel prerecording must remain null until authored media exists")
music = definition["music"]
if music["resourcePath"] != (
    "Turing/Audio/chapter03/chapter03-light-at-the-end-of-the-tunnel.mp3"
):
    fail("music resource path changed")
visual = definition["visual"]
expected_visual = {
    "portalDiameterMeters": 2.286,
    "startDistanceMeters": 30.48,
    "endDistanceMeters": 3.048,
    "approachDurationSeconds": 60.0,
    "angelInsideOffsetMeters": 1.0,
    "angelRootYOffsetMeters": -0.9,
    "domeRadiusMeters": 12.0,
    "domeCenterOffsetZMeters": -9.0,
}
if visual != expected_visual:
    fail(f"circular portal definition changed: {visual!r}")
if "timeline" in definition:
    fail("obsolete rectangle-tunnel timeline remains in production definition")

print("chapter03 verifier: PASS")
