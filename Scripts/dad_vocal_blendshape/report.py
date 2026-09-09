from __future__ import annotations

from pathlib import Path
from typing import Any

from Scripts.angel_projection_blendshape.deterministic_json import write


def write_validation_report(path: Path, value: dict[str, Any]) -> Path:
    write(path, value)
    return path
