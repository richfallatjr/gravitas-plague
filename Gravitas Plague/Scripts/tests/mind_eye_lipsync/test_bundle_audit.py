from pathlib import Path
import shutil
from types import SimpleNamespace

import mind_eye_lipsync.bundle_audit as bundle_audit
from phase7_test_support import write_complete_set


def test_bundle_audit_requires_exact_source_bytes(tmp_path: Path, monkeypatch) -> None:
    source = write_complete_set(tmp_path / "source")
    app = tmp_path / "Gravitas Plague.app"
    built = app / "Turing" / "MindsEye" / "AudioFrames"
    shutil.copytree(source, built)
    monkeypatch.setattr(bundle_audit, "validate_set", lambda *args, **kwargs: SimpleNamespace(is_valid=True))
    result = bundle_audit.audit_bundle(app, source)
    assert result.is_valid
    assert result.bundled_manifest_count == 37

