from pathlib import Path

from mind_eye_lipsync.quality_aggregate import analyze_quality
from phase7_test_support import write_complete_set, write_reports


def test_quality_summary_covers_all_speakers_and_poses(tmp_path: Path) -> None:
    manifests = write_complete_set(tmp_path / "manifests")
    reports = write_reports(manifests, tmp_path / "reports")
    summary = analyze_quality(manifests, reports, verify_sources=False)
    assert summary.is_valid
    assert len(summary.records) == 37
    assert all(summary.aggregate_pose_frame_counts.values())

