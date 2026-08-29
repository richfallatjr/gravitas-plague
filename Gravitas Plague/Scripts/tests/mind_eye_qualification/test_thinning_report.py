from mind_eye_qualification.thinning_report import parse_thinning_report


def test_thinning_failure_marker_is_hard_failure(tmp_path):
    report = tmp_path / "App Thinning Size Report.txt"
    report.write_text("variant failed because payload is too large", encoding="utf-8")
    result = parse_thinning_report(report)
    assert result["status"] == "FAIL"
    assert "failed" in result["failureMarkers"]
