from __future__ import annotations

from typing import Iterable, Sequence


def compatible_normal_offsets(
    base_normals: Sequence[Iterable[float]] | None,
    target_normals: Sequence[Iterable[float]] | None,
    point_count: int,
) -> tuple[tuple[float, float, float], ...] | None:
    if base_normals is None or target_normals is None:
        return None
    if len(base_normals) != point_count or len(target_normals) != point_count:
        return None
    output = []
    for base, target in zip(base_normals, target_normals):
        b = tuple(float(value) for value in base)
        t = tuple(float(value) for value in target)
        if len(b) != 3 or len(t) != 3:
            return None
        output.append((t[0] - b[0], t[1] - b[1], t[2] - b[2]))
    return tuple(output)
