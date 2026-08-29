from __future__ import annotations

import re
from pathlib import Path


def parse_weight(path: str | Path) -> int:
    stem = Path(path).stem.lower()
    explicit = re.search(r"(?:weight[-_]|w-)(\d+)(?:\D|$)", stem)
    trailing = re.search(r"_(\d+)$", stem)
    match = explicit or trailing
    value = int(match.group(1)) if match else 1
    if not 1 <= value <= 100:
        raise ValueError(f"Filler weight must be 1...100: {path}")
    return value


def unweighted_stem(path: str | Path) -> str:
    stem = Path(path).stem.lower()
    stem = re.sub(r"(?:[_-]?weight[-_]|[_-]?w-)\d+$", "", stem)
    return re.sub(r"_\d+$", "", stem)
