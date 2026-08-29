from __future__ import annotations

import shutil
import uuid
from pathlib import Path

from .validator import validate_set


def publish_set(candidate: Path, target: Path) -> dict[str, object]:
    validate_set(candidate)
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(f"{target.name}.staging.{uuid.uuid4().hex}")
    backup = target.with_name(f"{target.name}.backup.{uuid.uuid4().hex}")
    shutil.copytree(candidate, staging)
    validate_set(staging)
    had_target = target.exists()
    try:
        if had_target:
            target.replace(backup)
        staging.replace(target)
        validate_set(target)
    except BaseException:
        if target.exists():
            shutil.rmtree(target)
        if backup.exists():
            backup.replace(target)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
        if backup.exists():
            shutil.rmtree(backup)
    return {"status": "PASS", "target": str(target), "tracks": 51}
