from pathlib import Path

from mind_eye_qualification.archive_audit import audit_archive


def test_archive_requires_exactly_one_app(tmp_path):
    root = Path(__file__).resolve().parents[4]
    result = audit_archive(root, tmp_path / "Missing.xcarchive")
    assert result["status"] == "FAIL"
    assert "found 0" in result["errors"][0]
