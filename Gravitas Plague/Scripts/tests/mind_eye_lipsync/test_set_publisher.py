from pathlib import Path
from types import SimpleNamespace

from mind_eye_lipsync.deterministic_json import write_atomic_json
import mind_eye_lipsync.set_publisher as publisher
from phase7_test_support import write_complete_set


def test_publisher_installs_one_atomic_complete_directory(tmp_path: Path, monkeypatch) -> None:
    candidate = write_complete_set(tmp_path / "candidate")
    set_hash = __import__("json").loads((candidate / "index.json").read_text())["manifestSetSHA256"]
    comparison = tmp_path / "comparison.json"
    quality = tmp_path / "quality.json"
    write_atomic_json(comparison, {"status":"PASS","leftSetSHA256":set_hash,"rightSetSHA256":set_hash,"filesCompared":38,"differences":[]})
    write_atomic_json(quality, {"valid":True,"hardFailureCount":0})
    target = tmp_path / "resources" / "Turing" / "MindsEye" / "AudioFrames"
    monkeypatch.setattr(publisher, "CANONICAL_TARGET", target)
    monkeypatch.setattr(publisher, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(publisher, "validate_set", lambda *args, **kwargs: SimpleNamespace(is_valid=True))
    result = publisher.publish_set(candidate=candidate, comparison_report=comparison, quality_report=quality, target=target, replace_complete_set=False)
    assert result["status"] == "PASS"
    assert len(list(target.iterdir())) == 38

