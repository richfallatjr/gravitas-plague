#!/usr/bin/env python3
"""Compare Phase 3 A/B/C runs while enforcing experiment identity."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any

from analyze_turing_residency_memory import analyze, load_documents


IDENTITY_KEYS = (
    "textHash",
    "seed",
    "voiceID",
    "variantID",
    "admissionMode",
    "commandBufferProfile",
    "worldQualificationMode",
)


def identity(document: dict[str, Any]) -> tuple[Any, ...]:
    source = document.get("qualificationIdentity", document)
    return tuple(source.get(key) for key in IDENTITY_KEYS)


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round((len(ordered) - 1) * fraction))]


def numeric(documents: list[dict[str, Any]], key: str) -> list[float]:
    return [float(item[key]) for item in documents if isinstance(item.get(key), (int, float))]


def compare(paths: list[Path]) -> list[dict[str, Any]]:
    groups = [(path, load_documents([path])) for path in paths]
    all_documents = [document for _, documents in groups for document in documents]
    identities = {identity(document) for document in all_documents}
    if len(identities) != 1 or any(value is None for values in identities for value in values):
        raise ValueError(
            "Residency runs differ in, or omit, text/seed/voice/variant/admission/"
            "command-buffer/world qualification identity."
        )

    rows: list[dict[str, Any]] = []
    for path, documents in groups:
        if not documents:
            raise ValueError(f"No run documents in {path}")
        memory = analyze(documents)
        ownership = documents[0].get("residencyOwnership", {})
        first_audio = numeric(documents, "firstAudioSeconds")
        total_response = numeric(documents, "totalResponseSeconds")
        rows.append({
            "mode": documents[0].get("mode", documents[0].get("residencyMode")),
            "laneCount": ownership.get("actualLaneCount"),
            "uniqueResourceOwners": ownership.get("uniqueResidentResourceCount"),
            "uniqueWeightStores": ownership.get("uniqueWeightStoreCount"),
            "uniqueCloneBundles": ownership.get("uniqueCloneConditioningCount"),
            "sessionReadySeconds": statistics.median(numeric(documents, "sessionReadySeconds")) if numeric(documents, "sessionReadySeconds") else None,
            "secondLaneIncrementalFootprintMB": memory["secondLaneIncrementalFootprintMB"],
            "poolReadyFootprintMB": memory["medianPhysicalFootprintMBByBoundary"]["pool.ready"],
            "peakFootprintMB": memory["medianPhysicalFootprintMBByBoundary"]["run.peak"],
            "peakMLXActiveMB": memory["peakMLXActiveMB"],
            "peakMLXCacheMB": memory["peakMLXCacheMB"],
            "minimumAvailableMemoryMB": memory["minimumAvailableProcessMemoryMB"],
            "firstAudioP50Seconds": percentile(first_audio, 0.50),
            "firstAudioP95Seconds": percentile(first_audio, 0.95),
            "totalResponseP50Seconds": percentile(total_response, 0.50),
            "totalResponseP95Seconds": percentile(total_response, 0.95),
            "aggregateRealTimeFactor": statistics.median(numeric(documents, "aggregateRealTimeFactor")) if numeric(documents, "aggregateRealTimeFactor") else None,
            "outputParity": all(bool(item.get("outputParity", False)) for item in documents),
            "crashFailureCount": sum(bool(item.get("crashed", False) or item.get("failed", False)) for item in documents),
            "postUnloadResidualMB": memory["medianPhysicalFootprintMBByBoundary"]["qualification.quiescent.3s"],
        })
    baseline = next(
        (row for row in rows if row["mode"] == "independentFresh2"),
        None,
    )
    if baseline:
        independent_delta = baseline["secondLaneIncrementalFootprintMB"]
        for row in rows:
            if row["mode"] != "sharedImmutableFresh2":
                continue
            pool_savings = (
                baseline["poolReadyFootprintMB"] - row["poolReadyFootprintMB"]
                if baseline["poolReadyFootprintMB"] is not None
                and row["poolReadyFootprintMB"] is not None
                else None
            )
            required = (
                max(256.0, min(512.0, independent_delta * 0.60))
                if independent_delta is not None
                else None
            )
            row["warmPoolSavingsMB"] = pool_savings
            row["requiredWarmPoolSavingsMB"] = required
            row["materialSavingsGatePassed"] = (
                pool_savings >= required
                if pool_savings is not None and required is not None
                else None
            )
            row["peakSavingsMB"] = (
                baseline["peakFootprintMB"] - row["peakFootprintMB"]
                if baseline["peakFootprintMB"] is not None
                and row["peakFootprintMB"] is not None
                else None
            )
            row["availableMemoryGainMB"] = (
                row["minimumAvailableMemoryMB"] - baseline["minimumAvailableMemoryMB"]
                if row["minimumAvailableMemoryMB"] is not None
                and baseline["minimumAvailableMemoryMB"] is not None
                else None
            )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        rows = compare(arguments.inputs)
    except ValueError as error:
        print(f"FAIL: {error}")
        return 2
    rendered = json.dumps(rows, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
