from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from .constants import TIMELINE_SAMPLE_RATE
from .mfa_json import MFAAlignment
from .phones import ARPA_INVENTORY
from .vad import SpeechSpan, overlap_samples


@dataclass(frozen=True, slots=True)
class AlignmentQualityReport:
    aligned_word_count: int
    aligned_word_ratio: float
    spn_ratio: float
    unknown_phone_ratio: float
    warnings: tuple[str, ...]


def maximum_uncovered_samples(
    start: int,
    end: int,
    covered_ranges: Sequence[tuple[int, int]],
) -> int:
    """Return the longest contiguous uncovered gap, not cumulative pauses."""
    cursor = start
    maximum = 0
    for range_start, range_end in sorted(covered_ranges):
        clipped_start = max(start, range_start)
        clipped_end = min(end, range_end)
        if clipped_end <= clipped_start:
            continue
        if clipped_start > cursor:
            maximum = max(maximum, clipped_start - cursor)
        cursor = max(cursor, clipped_end)
        if cursor >= end:
            break
    return max(maximum, end - cursor)


def validate_alignment_quality(
    alignment: MFAAlignment,
    speech_spans: Sequence[SpeechSpan],
    *,
    transcript_token_count: int,
    config: dict[str, object],
) -> AlignmentQualityReport:
    if not alignment.words or not alignment.phones:
        raise ValueError("Alignment must contain words and phones")
    warnings: list[str] = []
    aligned_ratio = min(1.0, len(alignment.words) / max(1, transcript_token_count))
    non_silence = [
        phone for phone in alignment.phones
        if phone.normalized_phone.lower() not in {"", "<eps>", "sil", "sp", "silence"}
    ]
    spn_count = sum(phone.normalized_phone.lower() == "spn" for phone in non_silence)
    unknown_count = sum(
        phone.normalized_phone not in ARPA_INVENTORY and phone.normalized_phone.lower() != "spn"
        for phone in non_silence
    )
    denominator = max(1, len(non_silence))
    spn_ratio = spn_count / denominator
    unknown_ratio = unknown_count / denominator
    if aligned_ratio < float(config["minimumAlignedWordRatio"]):
        raise ValueError(f"Aligned word ratio {aligned_ratio:.4f} is below quality threshold")
    if spn_ratio > float(config["maximumSPNRatio"]):
        raise ValueError(f"SPN ratio {spn_ratio:.4f} exceeds quality threshold")
    if unknown_ratio > float(config["maximumUnknownPhoneRatio"]):
        raise ValueError(f"Unknown phone ratio {unknown_ratio:.4f} exceeds quality threshold")
    max_phone = int(float(config["maximumPhoneDurationSeconds"]) * TIMELINE_SAMPLE_RATE)
    max_word = int(float(config["maximumWordDurationSeconds"]) * TIMELINE_SAMPLE_RATE)
    for phone in non_silence:
        duration = phone.end_sample - phone.start_sample
        if duration > max_phone:
            raise ValueError(f"Phone exceeds duration gate: {phone.raw_phone} {duration} samples")
        outside = duration - overlap_samples(phone.start_sample, phone.end_sample, speech_spans)
        if outside > int(float(config["alignedPhoneOutsideSpeechFailureMs"]) * 48):
            raise ValueError(f"MFA speech outside VAD exceeds failure gate: {phone.raw_phone}")
        if outside > int(float(config["alignedPhoneOutsideSpeechWarningMs"]) * 48):
            warnings.append(f"alignedPhoneOutsideVAD:{phone.raw_phone}:{outside}")
    for word in alignment.words:
        if word.end_sample - word.start_sample > max_word:
            raise ValueError(f"Word exceeds duration gate: {word.label}")
    phone_ranges = [(phone.start_sample, phone.end_sample) for phone in non_silence]
    for speech in speech_spans:
        uncovered = maximum_uncovered_samples(
            speech.start_sample_48k,
            speech.end_sample_48k,
            phone_ranges,
        )
        if uncovered > int(float(config["vadSpeechWithoutPhoneFailureMs"]) * 48):
            raise ValueError("VAD speech without aligned phone exceeds failure gate")
        if uncovered > int(float(config["vadSpeechWithoutPhoneWarningMs"]) * 48):
            warnings.append(f"vadSpeechWithoutPhone:{speech.start_sample_48k}-{speech.end_sample_48k}")
    if alignment.boundary_clamp_count:
        warnings.append(f"alignmentBoundaryClamps:{alignment.boundary_clamp_count}")
    return AlignmentQualityReport(
        aligned_word_count=len(alignment.words),
        aligned_word_ratio=aligned_ratio,
        spn_ratio=spn_ratio,
        unknown_phone_ratio=unknown_ratio,
        warnings=tuple(sorted(warnings)),
    )
