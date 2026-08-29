from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any, Sequence

from .config import CONFIG_ROOT
from .constants import (
    EVIDENCE_BOUNDARY_ALLOWANCE,
    EVIDENCE_FALLBACK,
    EVIDENCE_MFA,
    EVIDENCE_VAD_SILENCE,
    EVIDENCE_VAD_SPEECH,
    MouthPose,
)
from .mfa_json import PhoneInterval, normalize_arpa_phone
from .vad import SpeechSpan, overlap_samples


ARPA_INVENTORY = frozenset(
    "AA AE AH AO AW AY B CH D DH EH ER EY F G HH IH IY JH K L M N NG OW OY "
    "P R S SH T TH UH UW V W Y Z ZH".split()
)


@dataclass(frozen=True, slots=True)
class PoseSpan:
    start_sample: int
    end_sample: int
    pose: MouthPose
    source_phone: str
    evidence_mask: int


@dataclass(frozen=True, slots=True)
class PhonePoseMap:
    direct_map: dict[str, MouthPose]
    compound_map: dict[str, tuple[tuple[MouthPose, float], ...]]
    silence_labels: frozenset[str]
    unknown_speech_labels: frozenset[str]
    anticipation_frames: dict[MouthPose, int]
    minimum_hold_frames: dict[MouthPose, int]
    unknown_speech_fallback: MouthPose
    unknown_silence_fallback: MouthPose


@dataclass(frozen=True, slots=True)
class PhoneMappingResult:
    spans: tuple[PoseSpan, ...]
    warnings: tuple[str, ...]
    fallback_phones: tuple[str, ...]


def load_phone_pose_map(path: Path | None = None) -> PhonePoseMap:
    path = path or CONFIG_ROOT / "phoneme_pose_map.json"
    raw = json.loads(path.read_text(encoding="utf-8"))
    if raw.get("schemaVersion") != 1 or raw.get("phoneSet") != "ARPA":
        raise ValueError("Unsupported phone-pose map")
    direct = {key: MouthPose(value) for key, value in raw["directMap"].items()}
    compound = {
        key: tuple((MouthPose(item["pose"]), float(item["fraction"])) for item in value)
        for key, value in raw["compoundMap"].items()
    }
    accounted = set(direct) | set(compound)
    if accounted != ARPA_INVENTORY:
        raise ValueError(
            "Phone map must account for every ARPA phone; "
            f"missing={sorted(ARPA_INVENTORY - accounted)} extra={sorted(accounted - ARPA_INVENTORY)}"
        )
    for phone, phases in compound.items():
        if not phases or abs(sum(value for _, value in phases) - 1) > 1e-9:
            raise ValueError(f"Compound phone fractions must sum to one: {phone}")
    anticipation = {MouthPose(key): int(value) for key, value in raw["anticipationFrames"].items()}
    holds = {MouthPose(key): int(value) for key, value in raw["minimumHoldFrames"].items()}
    if set(anticipation) != set(MouthPose) or set(holds) != set(MouthPose):
        raise ValueError("Every pose requires anticipation and hold configuration")
    return PhonePoseMap(
        direct_map=direct,
        compound_map=compound,
        silence_labels=frozenset(str(item).lower() for item in raw["silenceLabels"]),
        unknown_speech_labels=frozenset(str(item).lower() for item in raw["unknownSpeechLabels"]),
        anticipation_frames=anticipation,
        minimum_hold_frames=holds,
        unknown_speech_fallback=MouthPose(raw["unknownAlignedSpeechFallback"]),
        unknown_silence_fallback=MouthPose(raw["unknownSilenceFallback"]),
    )


def _split_compound(
    phone: PhoneInterval,
    phases: Sequence[tuple[MouthPose, float]],
    evidence: int,
) -> list[PoseSpan]:
    duration = phone.end_sample - phone.start_sample
    spans: list[PoseSpan] = []
    cursor = phone.start_sample
    accumulated = 0.0
    for index, (pose, fraction) in enumerate(phases):
        accumulated += fraction
        end = phone.end_sample if index == len(phases) - 1 else (
            phone.start_sample + int(duration * accumulated + 0.5)
        )
        end = min(phone.end_sample, max(cursor, end))
        if end > cursor:
            spans.append(PoseSpan(cursor, end, pose, phone.raw_phone, evidence))
        cursor = end
    if not spans or spans[0].start_sample != phone.start_sample or spans[-1].end_sample != phone.end_sample:
        raise ValueError(f"Compound phone split failed exact coverage: {phone.raw_phone}")
    return spans


def map_phone_intervals(
    phones: Sequence[PhoneInterval],
    speech_spans: Sequence[SpeechSpan],
    mapping: PhonePoseMap,
    *,
    boundary_allowance_samples: int = 12_000,
) -> PhoneMappingResult:
    spans: list[PoseSpan] = []
    warnings: list[str] = []
    fallback_phones: list[str] = []
    for phone in phones:
        raw_lower = phone.raw_phone.strip().lower()
        duration = phone.end_sample - phone.start_sample
        speech_overlap = overlap_samples(phone.start_sample, phone.end_sample, speech_spans)
        if raw_lower in mapping.silence_labels:
            spans.append(PoseSpan(
                phone.start_sample, phone.end_sample, MouthPose.REST, phone.raw_phone,
                EVIDENCE_MFA | EVIDENCE_VAD_SILENCE,
            ))
            continue
        evidence = EVIDENCE_MFA
        if speech_overlap:
            evidence |= EVIDENCE_VAD_SPEECH
        elif duration <= boundary_allowance_samples:
            evidence |= EVIDENCE_BOUNDARY_ALLOWANCE | EVIDENCE_VAD_SILENCE
            warnings.append(f"boundaryAllowance:{phone.raw_phone}:{phone.start_sample}-{phone.end_sample}")
        else:
            evidence |= EVIDENCE_VAD_SILENCE
            warnings.append(f"alignedPhoneSuppressedOutsideSpeech:{phone.raw_phone}:{phone.start_sample}-{phone.end_sample}")
            spans.append(PoseSpan(
                phone.start_sample,
                phone.end_sample,
                MouthPose.REST,
                phone.raw_phone,
                evidence,
            ))
            continue

        normalized = normalize_arpa_phone(phone.raw_phone)
        unknown = raw_lower in mapping.unknown_speech_labels or (
            normalized not in mapping.direct_map and normalized not in mapping.compound_map
        )
        if unknown:
            pose = mapping.unknown_speech_fallback if speech_overlap else mapping.unknown_silence_fallback
            spans.append(PoseSpan(
                phone.start_sample, phone.end_sample, pose, phone.raw_phone,
                evidence | EVIDENCE_FALLBACK,
            ))
            fallback_phones.append(phone.raw_phone)
            warnings.append(f"fallbackPhone:{phone.raw_phone}:{phone.start_sample}-{phone.end_sample}")
        elif normalized in mapping.compound_map:
            spans.extend(_split_compound(phone, mapping.compound_map[normalized], evidence))
        else:
            spans.append(PoseSpan(
                phone.start_sample, phone.end_sample, mapping.direct_map[normalized],
                phone.raw_phone, evidence,
            ))
    return PhoneMappingResult(tuple(spans), tuple(sorted(set(warnings))), tuple(fallback_phones))
