from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Sequence


@dataclass(frozen=True)
class SparseOffsets:
    indices: tuple[int, ...]
    values: tuple[tuple[float, float, float], ...]
    mean_displacement: float
    rms_displacement: float
    maximum_displacement: float


def compute_sparse_offsets(
    base_points: Sequence[Iterable[float]],
    target_points: Sequence[Iterable[float]],
    epsilon_meters: float,
) -> SparseOffsets:
    if len(base_points) != len(target_points):
        raise ValueError("point-count mismatch")
    indices: list[int] = []
    values: list[tuple[float, float, float]] = []
    magnitudes: list[float] = []
    for index, (base, target) in enumerate(zip(base_points, target_points)):
        b = tuple(float(value) for value in base)
        t = tuple(float(value) for value in target)
        if len(b) != 3 or len(t) != 3 or not all(map(math.isfinite, b + t)):
            raise ValueError(f"nonfinite or malformed point at index {index}")
        delta = (t[0] - b[0], t[1] - b[1], t[2] - b[2])
        magnitude = math.sqrt(sum(value * value for value in delta))
        if magnitude > epsilon_meters:
            indices.append(index)
            values.append(delta)
            magnitudes.append(magnitude)
    if not values:
        raise ValueError("target contains zero deformation")
    mean = sum(magnitudes) / len(magnitudes)
    rms = math.sqrt(sum(value * value for value in magnitudes) / len(magnitudes))
    return SparseOffsets(
        indices=tuple(indices),
        values=tuple(values),
        mean_displacement=mean,
        rms_displacement=rms,
        maximum_displacement=max(magnitudes),
    )
