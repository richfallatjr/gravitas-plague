from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .constants import MouthPose


def load_manual_override(path: Path, *, pr_id: str, frame_count: int) -> tuple[dict[str, object], ...]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or tuple(payload) != ("schemaVersion", "prID", "operations"):
        raise ValueError("Manual override must use the canonical schema/order")
    if payload["schemaVersion"] != 1 or payload["prID"] != pr_id:
        raise ValueError("Manual override schema/PR ID mismatch")
    operations = payload["operations"]
    if not isinstance(operations, list) or not operations:
        raise ValueError("Manual override operations must be nonempty")
    validated: list[dict[str, object]] = []
    previous_end = 0
    for index, raw in enumerate(operations):
        if not isinstance(raw, dict) or tuple(raw) != (
            "startFrame", "endFrameExclusive", "pose", "reason"
        ):
            raise ValueError(f"Manual override operation {index} has invalid keys/order")
        start = raw["startFrame"]
        end = raw["endFrameExclusive"]
        reason = raw["reason"]
        if (
            not isinstance(start, int) or isinstance(start, bool)
            or not isinstance(end, int) or isinstance(end, bool)
            or start < previous_end or start < 0 or end <= start or end > frame_count
            or not isinstance(reason, str) or not reason.strip()
        ):
            raise ValueError(f"Manual override operation {index} is unsafe or out of range")
        MouthPose(raw["pose"])
        validated.append(dict(raw))
        previous_end = end
    return tuple(validated)
