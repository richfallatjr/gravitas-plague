from __future__ import annotations

from pathlib import Path

from mind_eye_lipsync.dictionary import build_merged_dictionary
from mind_eye_lipsync.transcript import normalize_transcript


def test_reviewed_override_merges_without_touching_base(tmp_path: Path) -> None:
    base = tmp_path / "base.dict"
    base.write_text("known\tN OW1 N\n", encoding="utf-8")
    overrides = tmp_path / "overrides.dict"
    overrides.write_text("NOVEL  N AA1 V AH0 L\n", encoding="utf-8")
    destination = tmp_path / "merged.dict"
    result = build_merged_dictionary(
        base_dictionary=base,
        pronunciation_overrides=overrides,
        transcript=normalize_transcript("known novel"),
        g2p_model=tmp_path / "unused.zip",
        destination=destination,
        extraction_root=tmp_path / "extract",
    )
    assert result.oov_words == ("novel",)
    assert result.override_words == ("novel",)
    assert result.g2p_words == ()
    assert base.read_text() == "known\tN OW1 N\n"
    assert destination.read_text().endswith("novel\tN AA1 V AH0 L\n")
