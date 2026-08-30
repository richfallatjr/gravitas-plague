#!/usr/bin/env python3
"""Compare analyzed Phase 2 profiles with failure/parity gates first."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from analyze_mlx_command_buffers import analyze, load_documents


def compare(paths: list[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in paths:
        documents = load_documents([path])
        result = analyze(documents)
        run_metrics = next(
            (item.get("runMetrics") for item in documents if item.get("runMetrics")), {}
        )
        def maximum_field(name: str) -> float | None:
            values = [item.get(name) for item in documents]
            numeric = [float(value) for value in values if isinstance(value, (int, float))]
            return max(numeric) if numeric else None

        def minimum_field(name: str) -> float | None:
            values = [item.get(name) for item in documents]
            numeric = [float(value) for value in values if isinstance(value, (int, float))]
            return min(numeric) if numeric else None

        def percentile_field(name: str, key: str) -> float | None:
            for item in documents:
                value = item.get(name)
                if isinstance(value, dict) and isinstance(value.get(key), (int, float)):
                    return float(value[key])
            return None

        row = {
            "profile": result["resolvedProfile"],
            "admissionMode": result["admissionMode"],
            "runCount": len(documents),
            "crashCount": sum(bool(item.get("crashed", False)) for item in documents),
            "metalErrorCount": result["failures"],
            "bufferCount": result["totalBuffers"],
            "gpuP50Milliseconds": result["gpuMilliseconds"]["p50"],
            "gpuP95Milliseconds": result["gpuMilliseconds"]["p95"],
            "gpuP99Milliseconds": result["gpuMilliseconds"]["p99"],
            "gpuMaximumMilliseconds": result["gpuMilliseconds"]["maximum"],
            "maximumOperationCount": max(
                (item["operationCount"] for item in result["topSlowBuffers"]), default=0
            ),
            "maximumReferencedInputBytesEstimate": max(
                (item["referencedInputBytesEstimate"] for item in result["topSlowBuffers"]), default=0
            ),
            "singlePrimitiveLongBufferCount": (
                run_metrics.get("singlePrimitiveOver50msCount", 0)
                if isinstance(run_metrics, dict) else 0
            ),
            "firstAudioP50Seconds": percentile_field("firstAudioSeconds", "p50"),
            "firstAudioP95Seconds": percentile_field("firstAudioSeconds", "p95"),
            "totalResponseP50Seconds": percentile_field("totalResponseSeconds", "p50"),
            "totalResponseP95Seconds": percentile_field("totalResponseSeconds", "p95"),
            "peakPhysicalFootprintMB": maximum_field("peakPhysicalFootprintMB"),
            "minimumAvailableProcessMemoryMB": minimum_field(
                "minimumAvailableProcessMemoryMB"
            ),
            "peakMLXActiveMB": maximum_field("peakMLXActiveMB"),
            "peakMLXCacheMB": maximum_field("peakMLXCacheMB"),
            "outputParity": all(item.get("outputParity", True) for item in documents),
        }
        rows.append(row)
    return sorted(
        rows,
        key=lambda row: (
            row["crashCount"] > 0,
            row["metalErrorCount"] > 0,
            not row["outputParity"],
            row["gpuP99Milliseconds"],
            row["gpuMaximumMilliseconds"],
        ),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    rendered = json.dumps(compare(arguments.inputs), indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
