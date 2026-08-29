from pathlib import Path

from mind_eye_lipsync.set_validator import validate_set
from phase7_test_support import write_complete_set


def test_complete_set_passes_and_hidden_file_fails(tmp_path: Path) -> None:
    root = write_complete_set(tmp_path / "set")
    assert validate_set(root, verify_sources=False).is_valid
    (root / ".DS_Store").write_bytes(b"x")
    result = validate_set(root, verify_sources=False)
    assert not result.is_valid
    assert any(item.code == "hiddenFile" for item in result.diagnostics)

