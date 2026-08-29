from __future__ import annotations

import math
import statistics
from typing import Iterable, Optional


MIB = 1_048_576.0


def percentile(values: Iterable[float], fraction: float) -> Optional[float]:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    if not 0 <= fraction <= 1:
        raise ValueError("fraction must be between zero and one")
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def median(values: Iterable[float]) -> Optional[float]:
    items = [float(value) for value in values]
    return statistics.median(items) if items else None


def bytes_to_mib(value: int | float) -> float:
    return float(value) / MIB


def nonnegative_delta(after: int | float, before: int | float) -> float:
    delta = float(after) - float(before)
    if delta < 0:
        raise ValueError("memory delta is negative")
    return delta


def checkpoint_footprint(report: dict, checkpoint: str, *, last: bool = False) -> Optional[int]:
    values = [
        event["resource"]["process"]["physicalFootprintBytes"]
        for event in report.get("events", []) if event.get("checkpoint") == checkpoint
    ]
    if not values:
        return None
    return int(values[-1] if last else values[0])
