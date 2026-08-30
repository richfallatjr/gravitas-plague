#!/usr/bin/env python3
"""Analyze bounded MLX command-buffer diagnostics without loading app assets."""

from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path
from typing import Any, Iterable


def load_documents(paths: Iterable[Path]) -> list[dict[str, Any]]:
    documents: list[dict[str, Any]] = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        try:
            value = json.loads(text)
            documents.extend(value if isinstance(value, list) else [value])
            continue
        except json.JSONDecodeError:
            pass
        for line_number, line in enumerate(text.splitlines(), 1):
            if line.strip():
                try:
                    documents.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: {error}") from error
    return documents


def records_from(documents: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for document in documents:
        candidates = document.get("recentRecords", document.get("records", []))
        if isinstance(candidates, list):
            records.extend(item for item in candidates if isinstance(item, dict))
        elif "commandBufferID" in document:
            records.append(document)
    return sorted(records, key=lambda item: number(item, "sequence"))


def number(record: dict[str, Any], *keys: str) -> float:
    for key in keys:
        value = record.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return 0.0


def context(record: dict[str, Any]) -> dict[str, Any]:
    value = record.get("lastContext", record.get("context", {}))
    return value if isinstance(value, dict) else {}


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def correlation(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 2 or len(xs) != len(ys):
        return None
    mean_x, mean_y = statistics.fmean(xs), statistics.fmean(ys)
    numerator = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    denominator = math.sqrt(
        sum((x - mean_x) ** 2 for x in xs) *
        sum((y - mean_y) ** 2 for y in ys)
    )
    return numerator / denominator if denominator else None


def summarize_record(record: dict[str, Any]) -> dict[str, Any]:
    ctx = context(record)
    return {
        "sequence": int(number(record, "sequence")),
        "commandBufferID": int(number(record, "commandBufferID")),
        "gpuMilliseconds": number(record, "GPUSeconds", "gpuDurationSeconds") * 1000,
        "kernelMilliseconds": number(record, "kernelSeconds", "kernelDurationSeconds") * 1000,
        "operationCount": int(number(record, "encodedOperationCount")),
        "referencedInputBytesEstimate": int(number(record, "referencedInputBytesEstimate")),
        "primitiveCount": int(number(record, "primitiveCount")),
        "primitiveHash": record.get("primitiveHash"),
        "firstPrimitive": record.get("firstPrimitive", ""),
        "lastPrimitive": record.get("lastPrimitive", ""),
        "phase": ctx.get("phase"),
        "stage": ctx.get("stage"),
        "runID": ctx.get("runID"),
        "segmentIndex": ctx.get("segmentIndex"),
        "mindEyeInFlight": int(number(record, "mindEyeInFlightAtSubmit")),
        "appMetalInFlight": int(number(record, "appMetalInFlightAtSubmit")),
        "failed": bool(record.get("isFailure", record.get("failureEpoch", 0))),
    }


def analyze(documents: list[dict[str, Any]]) -> dict[str, Any]:
    records = records_from(documents)
    gpu = [number(record, "GPUSeconds", "gpuDurationSeconds") for record in records]
    kernel = [number(record, "kernelSeconds", "kernelDurationSeconds") for record in records]
    operations = [number(record, "encodedOperationCount") for record in records]
    byte_estimates = [number(record, "referencedInputBytesEstimate") for record in records]
    failures = [index for index, record in enumerate(records) if record.get("isFailure")]
    slowest = sorted(records, key=lambda item: number(item, "GPUSeconds", "gpuDurationSeconds"), reverse=True)

    def top_where(predicate: Any) -> list[dict[str, Any]]:
        return [summarize_record(item) for item in slowest if predicate(item)][:10]

    def phase_is(record: dict[str, Any], name: str) -> bool:
        return context(record).get("phase") == name

    profile = next((doc.get("profile") for doc in documents if doc.get("profile")), "unknown")
    admission = next((doc.get("admissionMode") for doc in documents if doc.get("admissionMode")), "unknown")
    configuration = next((doc.get("configuration") for doc in documents if doc.get("configuration")), None)
    preceding: list[dict[str, Any]] = []
    for index in failures:
        preceding.extend(summarize_record(item) for item in records[max(0, index - 16):index + 1])

    return {
        "resolvedProfile": profile,
        "admissionMode": admission,
        "configuration": configuration,
        "totalBuffers": len(records),
        "failures": len(failures),
        "gpuMilliseconds": {
            "p50": percentile(gpu, 0.50) * 1000,
            "p90": percentile(gpu, 0.90) * 1000,
            "p95": percentile(gpu, 0.95) * 1000,
            "p99": percentile(gpu, 0.99) * 1000,
            "maximum": max(gpu, default=0) * 1000,
        },
        "kernelMilliseconds": {
            "p50": percentile(kernel, 0.50) * 1000,
            "p95": percentile(kernel, 0.95) * 1000,
            "maximum": max(kernel, default=0) * 1000,
        },
        "durationHistogram": next(
            (doc.get("runMetrics", {}).get("durationHistogram") for doc in documents
             if isinstance(doc.get("runMetrics"), dict)), {}
        ),
        "operationCountDurationCorrelation": correlation(operations, gpu),
        "referencedInputBytesEstimateDurationCorrelation": correlation(byte_estimates, gpu),
        "mixedContextCount": sum(bool(record.get("mixedContext")) for record in records),
        "topSlowBuffers": [summarize_record(item) for item in slowest[:10]],
        "topSlowSinglePrimitiveBuffers": top_where(
            lambda item: number(item, "primitiveCount") <= 2 and
            number(item, "encodedOperationCount") <= 2
        ),
        "topSlowDecoderBuffers": top_where(lambda item: phase_is(item, "speechDecoder")),
        "topSlowDynamicTalkerBuffers": top_where(lambda item: phase_is(item, "dynamicTalker")),
        "topSlowCodePredictorBuffers": top_where(lambda item: phase_is(item, "codePredictor")),
        "buffersOverlappingMindEye": sum(number(item, "mindEyeInFlightAtSubmit") > 0 for item in records),
        "buffersOverlappingAppMetal": sum(number(item, "appMetalInFlightAtSubmit") > 0 for item in records),
        "failureAdjacentPreceding16": preceding,
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
