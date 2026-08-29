from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .report_schema import validate_report


def load_json(file_path: Path) -> Any:
    with file_path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_report_file(file_path: Path) -> dict[str, Any]:
    errors = validate_report(load_json(file_path))
    return {"file": str(file_path), "status": "PASS" if not errors else "FAIL", "errors": errors}


def validate_directory(directory: Path) -> dict[str, Any]:
    files = sorted(directory.glob("*.qualification.json"))
    results = [validate_report_file(item) for item in files]
    errors = [error for result in results for error in result["errors"]]
    if not files:
        errors.append("no qualification reports found")
    return {
        "status": "PASS" if not errors else "FAIL",
        "reportCount": len(files),
        "reports": results,
        "errors": errors,
    }
