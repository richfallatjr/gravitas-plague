from __future__ import annotations

import json
import math
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any


def reject_nonfinite(value: Any, path: str = "$") -> None:
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError(f"Nonfinite float at {path}")
    elif isinstance(value, dict):
        for key, child in value.items():
            reject_nonfinite(child, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, child in enumerate(value):
            reject_nonfinite(child, f"{path}[{index}]")


def canonical_json_bytes(value: Any) -> bytes:
    reject_nonfinite(value)
    text = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=False,
        indent=2,
        separators=(",", ": "),
    )
    return (text + "\n").encode("utf-8")


def write_atomic_json(path: Path, value: Any) -> bytes:
    encoded = canonical_json_bytes(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(
        mode="wb",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as temporary:
        temporary.write(encoded)
        temporary.flush()
        temp_path = Path(temporary.name)
    temp_path.replace(path)
    return encoded
