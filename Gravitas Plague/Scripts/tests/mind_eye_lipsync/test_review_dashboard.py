from pathlib import Path

from mind_eye_lipsync.review_dashboard import build_review_dashboard
from phase7_test_support import write_complete_set, write_reports


def test_dashboard_keeps_audio_external_and_decisions_unreviewed(tmp_path: Path) -> None:
    manifests = write_complete_set(tmp_path / "manifests")
    reports = write_reports(manifests, tmp_path / "reports")
    output = tmp_path / "review"
    result = build_review_dashboard(manifests, reports, output, verify_sources=False)
    assert result["entryCount"] == 37
    assert not list(output.rglob("*.mp3"))
    assert '"status": "unreviewed"' in (output / "review-decisions.json").read_text()

