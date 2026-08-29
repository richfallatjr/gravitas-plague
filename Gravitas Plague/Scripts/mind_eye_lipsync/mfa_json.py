from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
import json
from pathlib import Path
import re
from typing import Any, Sequence

from .constants import TIMELINE_SAMPLE_RATE


@dataclass(frozen=True, slots=True)
class WordInterval:
    label: str
    normalized_label: str
    start_sample: int
    end_sample: int


@dataclass(frozen=True, slots=True)
class PhoneInterval:
    raw_phone: str
    normalized_phone: str
    start_sample: int
    end_sample: int
    word_index: int | None


@dataclass(frozen=True, slots=True)
class MFAAlignment:
    words: tuple[WordInterval, ...]
    phones: tuple[PhoneInterval, ...]
    boundary_clamp_count: int


def repair_boundary_absorbed_phones(
    alignment: MFAAlignment,
    speech_spans: Sequence[Any],
    *,
    timeline_sample_count: int,
    maximum_phone_samples: int,
) -> tuple[MFAAlignment, tuple[str, ...]]:
    """Trim only an overlong first/last phone that absorbed boundary preroll/postroll.

    MFA can assign leading room tone to the first vowel when align_one has no
    preceding silence word. The VAD boundary is authoritative for semantic
    animation, so this repair never moves a phone into speech or changes an
    interior phone.
    """
    phones = list(alignment.phones)
    warnings: list[str] = []
    if not phones or not speech_spans:
        return alignment, ()

    first = phones[0]
    if first.start_sample == 0 and first.end_sample - first.start_sample > maximum_phone_samples:
        overlaps = [
            span for span in speech_spans
            if span.start_sample_48k < first.end_sample
            and span.end_sample_48k > first.start_sample
        ]
        if overlaps:
            # An absorbed interval can cross an earlier sound/VAD island before
            # the real opening syllable. The final overlapping island is the
            # one adjacent to this phone's semantic end boundary.
            repaired_start = max(first.start_sample, overlaps[-1].start_sample_48k)
            if 0 < first.end_sample - repaired_start <= maximum_phone_samples:
                phones[0] = PhoneInterval(
                    first.raw_phone,
                    first.normalized_phone,
                    repaired_start,
                    first.end_sample,
                    first.word_index,
                )
                warnings.append(
                    f"trimmedLeadingBoundaryAbsorption:{first.raw_phone}:{repaired_start}"
                )

    last = phones[-1]
    if last.end_sample == timeline_sample_count and last.end_sample - last.start_sample > maximum_phone_samples:
        overlaps = [
            span for span in speech_spans
            if span.start_sample_48k < last.end_sample
            and span.end_sample_48k > last.start_sample
        ]
        if overlaps:
            # Symmetrically, the first overlapping island is adjacent to the
            # semantic start of a trailing phone that absorbed postroll.
            repaired_end = min(last.end_sample, overlaps[0].end_sample_48k)
            if 0 < repaired_end - last.start_sample <= maximum_phone_samples:
                phones[-1] = PhoneInterval(
                    last.raw_phone,
                    last.normalized_phone,
                    last.start_sample,
                    repaired_end,
                    last.word_index,
                )
                warnings.append(
                    f"trimmedTrailingBoundaryAbsorption:{last.raw_phone}:{repaired_end}"
                )

    return MFAAlignment(
        words=alignment.words,
        phones=tuple(phones),
        boundary_clamp_count=alignment.boundary_clamp_count,
    ), tuple(warnings)


_STRESS_SUFFIX = re.compile(r"[012]$")


def normalize_arpa_phone(value: str) -> str:
    return _STRESS_SUFFIX.sub("", value.strip().upper())


def seconds_to_sample(value: Decimal, sample_rate: int = TIMELINE_SAMPLE_RATE) -> int:
    return int((value * sample_rate).to_integral_value(rounding=ROUND_HALF_UP))


def _entries(tiers: Any, name: str) -> list[Any]:
    if not isinstance(tiers, dict) or name not in tiers:
        raise ValueError(f"MFA JSON missing {name} tier")
    tier = tiers[name]
    if isinstance(tier, dict):
        tier = tier.get("entries", tier.get("intervals"))
    if not isinstance(tier, list):
        raise ValueError(f"MFA JSON {name} tier has unsupported shape")
    return tier


def _interval_fields(item: Any) -> tuple[Decimal, Decimal, str]:
    if isinstance(item, list) and len(item) == 3:
        begin, end, label = item
    elif isinstance(item, dict):
        begin = item.get("begin", item.get("start"))
        end = item.get("end", item.get("stop"))
        label = item.get("label", item.get("text", item.get("value")))
    else:
        raise ValueError("Unsupported MFA interval entry")
    if begin is None or end is None or label is None:
        raise ValueError("MFA interval is missing begin/end/label")
    return Decimal(str(begin)), Decimal(str(end)), str(label)


def parse_mfa_json(
    path: Path,
    *,
    timeline_sample_count: int,
    tolerance_ms: int = 20,
) -> MFAAlignment:
    payload = json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal)
    if not isinstance(payload, dict):
        raise ValueError("MFA JSON root must be an object")
    tiers = payload.get("tiers")
    tolerance = tolerance_ms * TIMELINE_SAMPLE_RATE // 1000
    clamp_count = 0

    def convert(entries: Sequence[Any], *, phones: bool) -> list[tuple[str, str, int, int]]:
        nonlocal clamp_count
        parsed = [_interval_fields(item) for item in entries]
        parsed.sort(key=lambda item: (item[0], item[1], item[2]))
        output: list[tuple[str, str, int, int]] = []
        previous_end = 0
        for begin, end, label in parsed:
            start_sample, end_sample = seconds_to_sample(begin), seconds_to_sample(end)
            if start_sample < -tolerance or end_sample > timeline_sample_count + tolerance:
                raise ValueError(f"MFA interval outside timeline tolerance: {label}")
            clamped_start = min(timeline_sample_count, max(0, start_sample))
            clamped_end = min(timeline_sample_count, max(0, end_sample))
            if clamped_start != start_sample or clamped_end != end_sample:
                clamp_count += 1
            if clamped_end < clamped_start or clamped_start < previous_end:
                raise ValueError(f"MFA intervals overlap or run backward: {label}")
            if clamped_end == clamped_start and label.strip():
                raise ValueError(f"Nonempty MFA interval has zero duration: {label}")
            normalized = normalize_arpa_phone(label) if phones else label.strip().lower()
            output.append((label, normalized, clamped_start, clamped_end))
            previous_end = clamped_end
        return output

    words_raw = convert(_entries(tiers, "words"), phones=False)
    phones_raw = convert(_entries(tiers, "phones"), phones=True)
    word_silence_labels = {"", "<eps>", "sil", "sp", "silence"}
    words = tuple(
        WordInterval(*item)
        for item in words_raw
        if item[3] > item[2] and item[1] not in word_silence_labels
    )
    phone_values: list[PhoneInterval] = []
    for raw, normalized, start, end in phones_raw:
        if end <= start:
            continue
        center = start + (end - start) // 2
        word_index = next(
            (index for index, word in enumerate(words) if word.start_sample <= center < word.end_sample),
            None,
        )
        phone_values.append(PhoneInterval(raw, normalized, start, end, word_index))
    if not words or not phone_values:
        raise ValueError("MFA alignment must contain nonempty word and phone intervals")
    return MFAAlignment(words, tuple(phone_values), clamp_count)
