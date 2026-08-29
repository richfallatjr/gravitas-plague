from __future__ import annotations

from pathlib import Path
import struct

import pytest

from mind_eye_lipsync.timeline import compare_decoder_counts, parse_pcm_wav, timeline_for_sample_count
from mind_eye_lipsync.transcript import normalize_transcript


def test_transcript_normalization_is_unicode_and_punctuation_deterministic() -> None:
    result = normalize_transcript("  Mike’s—well… here!  two-part  ")
    assert result.alignment_text == "Mike's well here two part"
    assert result.hash_text == "mike's well here two part"
    assert result.token_count == 5
    with pytest.raises(ValueError):
        normalize_transcript("…!!!")


def test_numeric_radio_and_pathogen_tokens_expand_deterministically() -> None:
    result = normalize_transcript("ATNV-15 at 5.3305 USB")
    assert result.alignment_text == "ATNV fifteen at five point three three zero five USB"
    assert result.substitutions == (
        "numericExpansion:15->fifteen",
        "numericExpansion:3305->three_three_zero_five",
        "numericExpansion:5->five",
    )


@pytest.mark.parametrize(("samples", "frames"), [(1, 1), (800, 1), (801, 2), (1600, 2)])
def test_exact_frame_count(samples: int, frames: int) -> None:
    timeline = timeline_for_sample_count(samples)
    assert timeline.frame_count == frames
    assert timeline.frame_range(frames - 1)[1] == samples


def _wav(samples: int, *, rate: int = 48_000, channels: int = 1, bits: int = 16) -> bytes:
    block = channels * bits // 8
    pcm = bytes(samples * block)
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * block, block, bits)
    return b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(pcm)) + b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm


def test_exact_pcm_wav_parser(tmp_path: Path) -> None:
    path = tmp_path / "timeline.wav"
    path.write_bytes(_wav(801))
    assert parse_pcm_wav(path).sample_count == 801
    path.write_bytes(_wav(800, rate=44_100))
    with pytest.raises(ValueError):
        parse_pcm_wav(path)


def test_decoder_parity_thresholds() -> None:
    assert compare_decoder_counts(10_000, 10_048).warning is None
    assert compare_decoder_counts(10_000, 10_049).warning
    with pytest.raises(ValueError):
        compare_decoder_counts(10_000, 10_401)
