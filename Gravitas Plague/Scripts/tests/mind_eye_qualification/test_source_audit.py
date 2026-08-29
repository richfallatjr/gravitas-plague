from pathlib import Path

from mind_eye_qualification.source_audit import audit_source


def test_repository_source_audit_passes():
    root = Path(__file__).resolve().parents[4]
    result = audit_source(root)
    assert result["status"] == "PASS", result["errors"]
    assert result["authoredManifestCount"] == 37
    assert result["indexCount"] == 1
