from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from .hashing import sha256_file
from .set_index import EXPECTED_MANIFEST_COUNT, expected_manifest_filenames


@dataclass(frozen=True, slots=True)
class SetFileDifference:
    relative_path: str
    left_sha256: str | None
    right_sha256: str | None
    first_differing_byte: int | None
    left_size: int | None
    right_size: int | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "relativePath": self.relative_path,
            "leftSHA256": self.left_sha256,
            "rightSHA256": self.right_sha256,
            "firstDifferingByte": self.first_differing_byte,
            "leftSize": self.left_size,
            "rightSize": self.right_size,
        }


@dataclass(frozen=True, slots=True)
class SetComparison:
    left_set_sha256: str
    right_set_sha256: str
    files_compared: int
    differences: tuple[SetFileDifference, ...]

    @property
    def is_identical(self) -> bool:
        return not self.differences

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": "PASS" if self.is_identical else "FAIL",
            "leftSetSHA256": self.left_set_sha256,
            "rightSetSHA256": self.right_set_sha256,
            "filesCompared": self.files_compared,
            "differences": [item.to_dict() for item in self.differences],
        }


def _first_difference(left: bytes, right: bytes) -> int | None:
    for index, (lhs, rhs) in enumerate(zip(left, right)):
        if lhs != rhs:
            return index
    return min(len(left), len(right)) if len(left) != len(right) else None


def _set_hash(directory: Path) -> str:
    index_path = directory / "index.json"
    if not index_path.is_file():
        return ""
    payload = json.loads(index_path.read_text(encoding="utf-8"))
    value = payload.get("manifestSetSHA256") if isinstance(payload, dict) else None
    return value if isinstance(value, str) else ""


def compare_sets(left: Path, right: Path) -> SetComparison:
    expected = tuple(sorted((*expected_manifest_filenames(), "index.json")))
    if len(expected) != EXPECTED_MANIFEST_COUNT + 1:
        raise ValueError("Internal expected-set definition is invalid")
    differences: list[SetFileDifference] = []
    for name in expected:
        left_path = left / name
        right_path = right / name
        left_bytes = left_path.read_bytes() if left_path.is_file() else None
        right_bytes = right_path.read_bytes() if right_path.is_file() else None
        if left_bytes is not None and right_bytes is not None and left_bytes == right_bytes:
            continue
        differences.append(SetFileDifference(
            relative_path=name,
            left_sha256=sha256_file(left_path) if left_bytes is not None else None,
            right_sha256=sha256_file(right_path) if right_bytes is not None else None,
            first_differing_byte=(
                _first_difference(left_bytes, right_bytes)
                if left_bytes is not None and right_bytes is not None
                else None
            ),
            left_size=len(left_bytes) if left_bytes is not None else None,
            right_size=len(right_bytes) if right_bytes is not None else None,
        ))
    left_extra = sorted(path.name for path in left.iterdir() if path.is_file() and path.name not in expected)
    right_extra = sorted(path.name for path in right.iterdir() if path.is_file() and path.name not in expected)
    for name in sorted(set(left_extra) | set(right_extra)):
        left_path = left / name
        right_path = right / name
        differences.append(SetFileDifference(
            relative_path=name,
            left_sha256=sha256_file(left_path) if left_path.is_file() else None,
            right_sha256=sha256_file(right_path) if right_path.is_file() else None,
            first_differing_byte=None,
            left_size=left_path.stat().st_size if left_path.is_file() else None,
            right_size=right_path.stat().st_size if right_path.is_file() else None,
        ))
    return SetComparison(
        left_set_sha256=_set_hash(left),
        right_set_sha256=_set_hash(right),
        files_compared=len(expected),
        differences=tuple(sorted(differences, key=lambda item: item.relative_path)),
    )

