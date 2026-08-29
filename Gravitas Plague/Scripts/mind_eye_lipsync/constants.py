from __future__ import annotations

from enum import Enum, IntEnum


class MouthPose(str, Enum):
    REST = "rest"
    SMALL = "small"
    WIDE = "wide"
    ROUND = "round"
    TEETH = "teeth"


class MouthLayerBit(IntEnum):
    REST = 1
    SMALL = 2
    WIDE = 4
    ROUND = 8
    TEETH = 16


POSE_TO_BIT: dict[MouthPose, int] = {
    MouthPose.REST: int(MouthLayerBit.REST),
    MouthPose.SMALL: int(MouthLayerBit.SMALL),
    MouthPose.WIDE: int(MouthLayerBit.WIDE),
    MouthPose.ROUND: int(MouthLayerBit.ROUND),
    MouthPose.TEETH: int(MouthLayerBit.TEETH),
}
BIT_TO_POSE = {value: key for key, value in POSE_TO_BIT.items()}
REQUIRED_POSES = tuple(MouthPose)

TIMELINE_SAMPLE_RATE = 48_000
ANALYSIS_SAMPLE_RATE = 16_000
FRAMES_PER_SECOND = 60
SAMPLES_PER_NOMINAL_FRAME = 800

EVIDENCE_MFA = 1
EVIDENCE_VAD_SPEECH = 2
EVIDENCE_VAD_SILENCE = 4
EVIDENCE_BOUNDARY_ALLOWANCE = 8
EVIDENCE_COARTICULATION = 16
EVIDENCE_FALLBACK = 32
EVIDENCE_MANUAL_OVERRIDE = 64

if TIMELINE_SAMPLE_RATE % FRAMES_PER_SECOND:
    raise RuntimeError("Timeline sample rate must divide evenly by frame rate.")
if SAMPLES_PER_NOMINAL_FRAME != TIMELINE_SAMPLE_RATE // FRAMES_PER_SECOND:
    raise RuntimeError("Nominal frame size must match the timeline rate and frame rate.")
