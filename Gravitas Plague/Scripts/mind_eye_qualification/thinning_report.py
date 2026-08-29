from __future__ import annotations

import json
import plistlib
import re
from pathlib import Path
from typing import Any


FAILURE_PATTERN = re.compile(r"(exceed|too large|failure|failed|error)", re.IGNORECASE)


def parse_thinning_report(file_path: Path) -> dict[str, Any]:
    raw = file_path.read_bytes()
    parsed: Any = None
    format_name = "text"
    try:
        parsed = plistlib.loads(raw)
        format_name = "plist"
    except Exception:
        try:
            parsed = json.loads(raw.decode("utf-8"))
            format_name = "json"
        except Exception:
            parsed = raw.decode("utf-8", errors="replace")
    searchable = json.dumps(parsed, sort_keys=True) if not isinstance(parsed, str) else parsed
    failures = sorted(set(match.group(0).lower() for match in FAILURE_PATTERN.finditer(searchable)))
    return {
        "schemaVersion": 1,
        "status": "FAIL" if failures else "PASS",
        "file": str(file_path),
        "format": format_name,
        "bytes": len(raw),
        "failureMarkers": failures,
    }
