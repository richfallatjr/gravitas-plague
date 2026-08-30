#!/usr/bin/env python3
"""Analyze Phase 3 memory boundaries without inventing missing device samples."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any


def load_documents(paths: list[Path]) -> list[dict[str, Any]]:
    documents: list[dict[str, Any]] = []
    for path in paths:
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            continue
        try:
            value = json.loads(text)
            documents.extend(value if isinstance(value, list) else [value])
        except json.JSONDecodeError:
            for line in text.splitlines():
                value = json.loads(line)
                documents.extend(value if isinstance(value, list) else [value])
    return [item for item in documents if isinstance(item, dict)]


def samples(document: dict[str, Any]) -> list[dict[str, Any]]:
    value = document.get("memorySamples", document.get("residencyMemorySamples", []))
    return value if isinstance(value, list) else []


def number(sample: dict[str, Any], key: str) -> float | None:
    snapshot = sample.get("snapshot", sample)
    value = snapshot.get(key) if isinstance(snapshot, dict) else None
    return float(value) if isinstance(value, (int, float)) else None


def median_at(
    documents: list[dict[str, Any]], label: str, key: str
) -> float | None:
    values = [
        value
        for document in documents
        for sample in samples(document)
        if sample.get("label") == label
        for value in [number(sample, key)]
        if value is not None
    ]
    return statistics.median(values) if values else None


def subtract(lhs: float | None, rhs: float | None) -> float | None:
    return lhs - rhs if lhs is not None and rhs is not None else None


def analyze(documents: list[dict[str, Any]]) -> dict[str, Any]:
    modes = sorted({str(item.get("mode", item.get("residencyMode", "unknown"))) for item in documents})
    boundaries = {
        label: median_at(documents, label, "physicalFootprintMB")
        for label in (
            "lane0.afterEngine",
            "lane1.afterEngine",
            "pool.ready",
            "run.peak",
            "pool.afterFinalCacheClear",
            "qualification.quiescent.250ms",
            "qualification.quiescent.1s",
            "qualification.quiescent.3s",
        )
    }
    minimum_available_values = [
        value
        for document in documents
        for sample in samples(document)
        for value in [number(sample, "availableProcessMemoryMB")]
        if value is not None
    ]
    peak_mlx_values = [
        value
        for document in documents
        for sample in samples(document)
        for value in [number(sample, "MLXActiveMB")]
        if value is not None
    ]
    peak_mlx_cache_values = [
        value
        for document in documents
        for sample in samples(document)
        for value in [number(sample, "MLXCacheMB")]
        if value is not None
    ]
    second_lane_delta = subtract(
        boundaries["lane1.afterEngine"], boundaries["lane0.afterEngine"]
    )
    return {
        "modes": modes,
        "runCount": len(documents),
        "medianPhysicalFootprintMBByBoundary": boundaries,
        "secondLaneIncrementalFootprintMB": second_lane_delta,
        "minimumAvailableProcessMemoryMB": min(minimum_available_values) if minimum_available_values else None,
        "peakMLXActiveMB": max(peak_mlx_values) if peak_mlx_values else None,
        "peakMLXCacheMB": max(peak_mlx_cache_values) if peak_mlx_cache_values else None,
        "hasRequiredDeviceBoundaries": all(value is not None for value in boundaries.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    result = analyze(load_documents(arguments.inputs))
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0 if result["hasRequiredDeviceBoundaries"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
