from __future__ import annotations

from decimal import Decimal
from pathlib import Path

import pytest

from mind_eye_lipsync.mfa_json import (
    MFAAlignment,
    PhoneInterval,
    WordInterval,
    parse_mfa_json,
    repair_boundary_absorbed_phones,
    seconds_to_sample,
)
from mind_eye_lipsync.vad import SpeechSpan


def test_pinned_mfa_fixture_parses_words_phones_stress_and_rounding() -> None:
    path = Path(__file__).with_name("fixtures") / "mfa_align_one_3_3_9.json"
    alignment = parse_mfa_json(path, timeline_sample_count=60_000)
    assert [word.normalized_label for word in alignment.words] == ["sample", "speaker"]
    stressed = next(phone for phone in alignment.phones if phone.raw_phone == "AE1")
    assert stressed.normalized_phone == "AE"
    assert alignment.phones[0].normalized_phone == "SIL"
    assert seconds_to_sample(Decimal("0.0000104166667")) == 1


def test_unknown_mfa_schema_rejected(tmp_path: Path) -> None:
    path = tmp_path / "bad.json"
    path.write_text('{"intervals": []}', encoding="utf-8")
    with pytest.raises(ValueError):
        parse_mfa_json(path, timeline_sample_count=48_000)


def test_pinned_shape_is_sorted_before_overlap_validation(tmp_path: Path) -> None:
    path = tmp_path / "alignment.json"
    path.write_text(
        '{"tiers":{"words":{"entries":[[0.5,1,"two"],[0,0.5,"one"]]},'
        '"phones":{"entries":[[0.5,1,"UW1"],[0,0.5,"W"]]}}}',
        encoding="utf-8",
    )
    alignment = parse_mfa_json(path, timeline_sample_count=48_000)
    assert [word.normalized_label for word in alignment.words] == ["one", "two"]
    assert [phone.raw_phone for phone in alignment.phones] == ["W", "UW1"]


def test_only_overlong_timeline_boundary_phone_is_trimmed_to_vad() -> None:
    alignment = MFAAlignment(
        words=(WordInterval("I'm", "i'm", 0, 150_000),),
        phones=(
            PhoneInterval("AH0", "AH", 0, 146_880, 0),
            PhoneInterval("M", "M", 146_880, 150_000, 0),
        ),
        boundary_clamp_count=0,
    )
    repaired, warnings = repair_boundary_absorbed_phones(
        alignment,
        (
            SpeechSpan(86_016, 122_880),
            SpeechSpan(143_000, 151_000),
        ),
        timeline_sample_count=200_000,
        maximum_phone_samples=57_600,
    )
    assert repaired.phones[0].start_sample == 143_000
    assert repaired.phones[1] == alignment.phones[1]
    assert warnings == ("trimmedLeadingBoundaryAbsorption:AH0:143000",)


def test_trailing_boundary_repair_uses_speech_island_adjacent_to_phone_start() -> None:
    alignment = MFAAlignment(
        words=(WordInterval("end", "end", 50_000, 200_000),),
        phones=(
            PhoneInterval("EH1", "EH", 50_000, 55_000, 0),
            PhoneInterval("ND", "ND", 55_000, 200_000, 0),
        ),
        boundary_clamp_count=0,
    )
    repaired, warnings = repair_boundary_absorbed_phones(
        alignment,
        (
            SpeechSpan(50_000, 62_000),
            SpeechSpan(150_000, 190_000),
        ),
        timeline_sample_count=200_000,
        maximum_phone_samples=57_600,
    )
    assert repaired.phones[0] == alignment.phones[0]
    assert repaired.phones[1].end_sample == 62_000
    assert warnings == ("trimmedTrailingBoundaryAbsorption:ND:62000",)
