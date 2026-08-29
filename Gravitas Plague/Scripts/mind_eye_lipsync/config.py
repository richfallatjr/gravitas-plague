from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path
from typing import Any

from .constants import (
    ANALYSIS_SAMPLE_RATE,
    FRAMES_PER_SECOND,
    TIMELINE_SAMPLE_RATE,
)
from .hashing import sha256_file


PACKAGE_ROOT = Path(__file__).resolve().parent
SCRIPTS_ROOT = PACKAGE_ROOT.parent
PROJECT_ROOT = SCRIPTS_ROOT.parent.parent
RESOURCES_ROOT = PROJECT_ROOT / "Gravitas Plague" / "TuringResources"
DESCRIPTOR_ROOT = RESOURCES_ROOT / "Turing" / "Prerecordings"
AUDIO_ROOT = RESOURCES_ROOT / "Turing" / "Audio" / "prerecordings"
CONFIG_ROOT = PACKAGE_ROOT / "config"
TOOLCHAIN_ROOT = PACKAGE_ROOT / "toolchain"


@dataclass(frozen=True, slots=True)
class CompilerPaths:
    project_root: Path = PROJECT_ROOT
    resources_root: Path = RESOURCES_ROOT
    descriptor_root: Path = DESCRIPTOR_ROOT
    audio_root: Path = AUDIO_ROOT
    config_root: Path = CONFIG_ROOT
    toolchain_root: Path = TOOLCHAIN_ROOT


@dataclass(frozen=True, slots=True)
class CompilerConfiguration:
    raw: dict[str, Any]
    sha256: str

    @property
    def compiler_version(self) -> str:
        return str(self.raw["compilerVersion"])

    def section(self, name: str) -> dict[str, Any]:
        value = self.raw.get(name)
        if not isinstance(value, dict):
            raise ValueError(f"Missing compiler configuration section: {name}")
        return value


def read_json_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return value


def _finite_number(value: Any, label: str, minimum: float, maximum: float) -> None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{label} must be numeric")
    if not math.isfinite(float(value)) or not minimum <= float(value) <= maximum:
        raise ValueError(f"{label} is outside {minimum}...{maximum}")


def load_compiler_configuration(path: Path | None = None) -> CompilerConfiguration:
    path = path or CONFIG_ROOT / "compiler_config.json"
    raw = read_json_object(path)
    if raw.get("schemaVersion") != 1:
        raise ValueError("Compiler configuration schemaVersion must be 1")
    timeline = raw.get("timeline", {})
    if timeline != {
        "sampleRate": TIMELINE_SAMPLE_RATE,
        "framesPerSecond": FRAMES_PER_SECOND,
        "channels": 1,
        "sampleFormat": "s16le",
    }:
        raise ValueError("Compiler timeline contract must remain 48 kHz/60 Hz/mono s16le")
    analysis = raw.get("analysisAudio", {})
    if analysis.get("sampleRate") != ANALYSIS_SAMPLE_RATE or analysis.get("channels") != 1:
        raise ValueError("Analysis audio must remain 16 kHz mono")
    ranges = {
        "timeline.sampleRate": (raw["timeline"]["sampleRate"], 8_000, 192_000),
        "timeline.framesPerSecond": (raw["timeline"]["framesPerSecond"], 1, 240),
        "timeline.channels": (raw["timeline"]["channels"], 1, 8),
        "analysisAudio.sampleRate": (raw["analysisAudio"]["sampleRate"], 8_000, 192_000),
        "analysisAudio.channels": (raw["analysisAudio"]["channels"], 1, 8),
        "vad.threshold": (raw["vad"]["threshold"], 0, 1),
        "vad.negativeThreshold": (raw["vad"]["negativeThreshold"], 0, 1),
        "vad.minSpeechDurationMs": (raw["vad"]["minSpeechDurationMs"], 0, 60_000),
        "vad.minSilenceDurationMs": (raw["vad"]["minSilenceDurationMs"], 0, 60_000),
        "vad.speechPadMs": (raw["vad"]["speechPadMs"], 0, 10_000),
        "vad.windowSamples": (raw["vad"]["windowSamples"], 1, 65_536),
        "vad.maximumSpeechDurationSeconds": (
            raw["vad"]["maximumSpeechDurationSeconds"], 1, 86_400
        ),
        "alignment.numJobs": (raw["alignment"]["numJobs"], 1, 1),
        "alignment.beam": (raw["alignment"]["beam"], 1, 10_000),
        "alignment.retryBeam": (raw["alignment"]["retryBeam"], 1, 100_000),
        "alignment.phoneBoundaryToleranceMs": (
            raw["alignment"]["phoneBoundaryToleranceMs"], 0, 1_000
        ),
        "adjudication.frameSpeechOverlapThreshold": (
            raw["adjudication"]["frameSpeechOverlapThreshold"], 0, 1
        ),
        "adjudication.alignedPhoneOutsideSpeechWarningMs": (
            raw["adjudication"]["alignedPhoneOutsideSpeechWarningMs"], 0, 60_000
        ),
        "adjudication.alignedPhoneOutsideSpeechFailureMs": (
            raw["adjudication"]["alignedPhoneOutsideSpeechFailureMs"], 0, 60_000
        ),
        "adjudication.vadSpeechWithoutPhoneWarningMs": (
            raw["adjudication"]["vadSpeechWithoutPhoneWarningMs"], 0, 60_000
        ),
        "adjudication.vadSpeechWithoutPhoneFailureMs": (
            raw["adjudication"]["vadSpeechWithoutPhoneFailureMs"], 0, 60_000
        ),
        "adjudication.maximumUnknownPhoneRatio": (
            raw["adjudication"]["maximumUnknownPhoneRatio"], 0, 1
        ),
        "adjudication.maximumSPNRatio": (
            raw["adjudication"]["maximumSPNRatio"], 0, 1
        ),
        "adjudication.minimumAlignedWordRatio": (
            raw["adjudication"]["minimumAlignedWordRatio"], 0, 1
        ),
        "adjudication.maximumPhoneDurationSeconds": (
            raw["adjudication"]["maximumPhoneDurationSeconds"], 0.001, 60
        ),
        "adjudication.maximumWordDurationSeconds": (
            raw["adjudication"]["maximumWordDurationSeconds"], 0.001, 600
        ),
        "coarticulation.boundaryContiguityMs": (
            raw["coarticulation"]["boundaryContiguityMs"], 0, 1_000
        ),
        "coarticulation.silenceBarrierFrames": (
            raw["coarticulation"]["silenceBarrierFrames"], 1, 60
        ),
        "deterministicJSON.indent": (raw["deterministicJSON"]["indent"], 0, 8),
        "deterministicJSON.floatDecimalPlaces": (
            raw["deterministicJSON"]["floatDecimalPlaces"], 1, 17
        ),
    }
    for label, (value, minimum, maximum) in ranges.items():
        _finite_number(value, label, minimum, maximum)
    if raw["vad"]["negativeThreshold"] > raw["vad"]["threshold"]:
        raise ValueError("VAD negativeThreshold cannot exceed threshold")
    if raw["alignment"]["retryBeam"] < raw["alignment"]["beam"]:
        raise ValueError("MFA retryBeam cannot be smaller than beam")
    if raw["adjudication"]["alignedPhoneOutsideSpeechFailureMs"] < raw["adjudication"]["alignedPhoneOutsideSpeechWarningMs"]:
        raise ValueError("Aligned-phone failure threshold cannot precede its warning threshold")
    if raw["adjudication"]["vadSpeechWithoutPhoneFailureMs"] < raw["adjudication"]["vadSpeechWithoutPhoneWarningMs"]:
        raise ValueError("VAD-without-phone failure threshold cannot precede its warning threshold")
    if raw["alignment"].get("outputFormat") != "json" or raw["alignment"].get("numJobs") != 1:
        raise ValueError("MFA authoring must remain single-job JSON output")
    for section, key, expected in (
        ("alignment", "singleSpeaker", True),
        ("alignment", "cleanTemporaryDirectory", True),
        ("coarticulation", "singleFrameRepairEnabled", True),
        ("deterministicJSON", "ensureASCII", False),
        ("deterministicJSON", "trailingNewline", True),
    ):
        if raw[section].get(key) is not expected:
            raise ValueError(f"{section}.{key} must remain {expected}")
    return CompilerConfiguration(raw=raw, sha256=sha256_file(path))
