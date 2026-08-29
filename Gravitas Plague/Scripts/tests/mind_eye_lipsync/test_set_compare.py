from pathlib import Path
import shutil

from mind_eye_lipsync.set_compare import compare_sets
from phase7_test_support import write_complete_set


def test_set_compare_requires_raw_byte_identity(tmp_path: Path) -> None:
    left = write_complete_set(tmp_path / "left")
    right = tmp_path / "right"
    shutil.copytree(left, right)
    assert compare_sets(left, right).is_identical
    manifest = next(right.glob("*.mouthframes.json"))
    manifest.write_bytes(manifest.read_bytes() + b" ")
    result = compare_sets(left, right)
    assert not result.is_identical
    assert result.differences[0].first_differing_byte is not None

