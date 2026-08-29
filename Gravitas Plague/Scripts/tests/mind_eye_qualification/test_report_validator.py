import json

from mind_eye_qualification.report_validator import validate_directory, validate_report_file
from test_report_schema import minimal_report


def test_file_and_directory_validation(tmp_path):
    report = tmp_path / "one.qualification.json"
    report.write_text(json.dumps(minimal_report()), encoding="utf-8")
    assert validate_report_file(report)["status"] == "PASS"
    result = validate_directory(tmp_path)
    assert result["status"] == "PASS"
    assert result["reportCount"] == 1
