#!/usr/bin/env python3
from pathlib import Path
import json
import re
import subprocess
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
ANGEL_PR = ROOT / (
    "Gravitas Plague/TuringResources/Turing/Audio/chapter03/"
    "pr-angel-01.mp3"
)
ANGEL_PR_DESCRIPTOR = ROOT / (
    "Gravitas Plague/TuringResources/Turing/Cinematics/Chapter03/"
    "pr_angel_01.json"
)
PICKER_ART = ROOT / (
    "Gravitas Plague/Gravitas Plague/Assets.xcassets/"
    "episode-chapter-3-button.imageset/episode-chapter-3-button.png"
)
ANIMATED_ANGEL = ROOT / "angel_biped.usdz"
STATIC_ANGEL = ROOT / "angel_posed_01.usdz"
HEAVEN = ROOT / "heaven-sunrise.exr"
AUDIO_PLAYER_SOURCE = ROOT / (
    "Gravitas Plague/Gravitas Plague/Story/Audio/"
    "StorySpatialPrerecordingPlayer.swift"
)


def fail(message: str) -> None:
    print(f"chapter03 verifier: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


sources = "\n".join(path.read_text() for path in CHAPTER.rglob("*.swift"))
sources += "\n" + AUDIO_PLAYER_SOURCE.read_text()
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
if not ANIMATED_ANGEL.is_file() or ANIMATED_ANGEL.stat().st_size == 0:
    fail("Chapter 3 animated angel USDZ is missing or empty")
if not STATIC_ANGEL.is_file() or STATIC_ANGEL.stat().st_size == 0:
    fail("Chapter 3 static posed angel USDZ is missing or empty")
if not HEAVEN.is_file() or HEAVEN.stat().st_size == 0:
    fail("Chapter 3 heaven EXR is missing or empty")
if "Chapter03AngelPortalEntity.load" not in sources:
    fail("Chapter 3 presenter does not install the static portal angel")
if "angel_float_pose_01" not in sources:
    fail("Chapter 3 retained animated variant lost its authored floating pose")
if "activeVariant: PresentationVariant = .staticPosed" not in sources:
    fail("Chapter 3 is not configured to use the static posed angel")
if "angel_posed_01" not in sources:
    fail("Chapter 3 active portal path does not reference angel_posed_01.usdz")
material_dump = subprocess.run(
    [
        "/usr/bin/usdcat",
        str(STATIC_ANGEL),
        "--flatten",
        "--mask",
        "/root/_materials",
    ],
    check=True,
    capture_output=True,
    text=True,
).stdout
if "textures/angel_emission.png" not in material_dump:
    fail("Chapter 3 static angel emission texture is not connected")
if "angel_emission_5x.exr" in material_dump:
    fail("Chapter 3 static angel must retain the authored PNG emission texture")
for required_emission_contract in (
    "Chapter03AngelEmissionApplier.apply",
    "static let targetIntensity: Float = 1.0",
    "pbr.emissiveIntensity = targetIntensity",
    "entity.components.set(model)",
    "PlagueNativeBloomInstaller.installStrictBloom(on: portalWorld)",
):
    if required_emission_contract not in sources:
        fail(f"Chapter 3 Angel runtime emission contract is missing: {required_emission_contract}")
if "emissiveIntensity *=" in sources:
    fail("Chapter 3 Angel emission multiplies an unknown imported scalar")
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
if not ANGEL_PR.is_file() or ANGEL_PR.stat().st_size == 0:
    fail("canonical Chapter 3 Angel PR is missing or empty")
if not ANGEL_PR_DESCRIPTOR.is_file():
    fail("Chapter 3 Angel PR descriptor is missing")
angel_definition = definition.get("angelPrerecording")
expected_angel_definition = {
    "descriptorResourcePath": "Turing/Cinematics/Chapter03/pr_angel_01.json",
    "trigger": "atPortalArrival",
    "musicDuckGainDB": -23.0,
    "duckAttackSeconds": 0.75,
    "duckReleaseSeconds": 0.75,
}
if angel_definition != expected_angel_definition:
    fail(f"Angel PR alignment contract changed: {angel_definition!r}")
angel_descriptor = json.loads(ANGEL_PR_DESCRIPTOR.read_text())
if angel_descriptor.get("audioFile") != "Turing/Audio/chapter03/pr-angel-01.mp3":
    fail("Angel PR descriptor audio path changed")
if angel_descriptor.get("outputRoute") != "cinematicEmitterSpatial":
    fail("Angel PR is not routed to the cinematic emitter")
for required_audio_contract in (
    "loadingStrategy: .stream",
    "controller.completionHandler",
    "portalArrivalStartMediaTime",
    "musicDuckGainDB",
):
    if required_audio_contract not in sources:
        fail(f"Angel PR playback contract is missing: {required_audio_contract}")
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
    "postApproachTravelMeters": 0.9144,
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
