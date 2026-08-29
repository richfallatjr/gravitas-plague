from pathlib import Path

from mind_eye_lipsync.set_index import build_index_payload, validate_index_object
from phase7_test_support import write_complete_set


def test_complete_index_is_deterministic_and_has_locked_counts(tmp_path: Path) -> None:
    root = write_complete_set(tmp_path / "set")
    first = build_index_payload(root, verify_sources=False)
    second = build_index_payload(root, verify_sources=False)
    assert first == second
    assert len(first["entries"]) == 37
    assert first["summary"]["speakerManifestCounts"] == {
        "big_mike": 10, "rich": 15, "broadcaster": 5, "cateye81": 5, "dad": 2,
    }
    validate_index_object(first)

