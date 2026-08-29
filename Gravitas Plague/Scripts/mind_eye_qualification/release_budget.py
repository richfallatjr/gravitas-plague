from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


def load_budget(file_path: Path) -> dict[str, Any]:
    with file_path.open("r", encoding="utf-8") as handle:
        document = json.load(handle)
    errors = validate_budget(document)
    if errors:
        raise ValueError("; ".join(errors))
    return document


def validate_budget(document: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        return ["budget schemaVersion must equal 1"]
    if document.get("budgetVersion") != "mind-eye-release-budget/1":
        errors.append("budgetVersion is unsupported")
    for section in ("memory", "latency", "cpu", "gpu", "stability", "bundle"):
        values = document.get(section)
        if not isinstance(values, dict) or not values:
            errors.append(f"{section} must be a nonempty object")
            continue
        for name, value in values.items():
            items = value if isinstance(value, list) else [value]
            for item in items:
                if not isinstance(item, (int, float)) or isinstance(item, bool):
                    errors.append(f"{section}.{name} must be numeric")
                elif not math.isfinite(float(item)) or item < 0:
                    errors.append(f"{section}.{name} must be finite and nonnegative")
    return errors


def evaluate_budget(measurements: dict[str, Any], budget: dict[str, Any]) -> dict[str, Any]:
    gates = {
        "activeIncrementMiB": budget["memory"]["maximumActiveIncrementMiB"],
        "qwenOverlapIncrementMiB": budget["memory"]["maximumQwenOverlapIncrementVersusQwenControlMiB"],
        "postDismissResidualMiB": budget["memory"]["maximumPostDismissResidualMiB"],
        "secondRunResidualGrowthMiB": budget["memory"]["maximumSecondRunResidualGrowthMiB"],
        "tenCycleResidualGrowthMiB": budget["memory"]["maximumTenCycleResidualGrowthMiB"],
        "audioStartP95RegressionMilliseconds": budget["latency"]["maximumActualAudioStartP95RegressionMilliseconds"],
        "mainThreadP95RegressionMilliseconds": budget["cpu"]["maximumMainThreadP95RegressionMilliseconds"],
        "compositorEncodeP95Milliseconds": budget["cpu"]["maximumCompositorEncodeP95Milliseconds"],
        "compositorGPUFractionOfFrameInterval": budget["gpu"]["maximumCompositorGPUFractionOfFrameInterval"],
        "routineCropClampRate": budget["gpu"]["maximumRoutineCropClampRate"],
    }
    results = []
    for name, maximum in gates.items():
        value = measurements.get(name)
        status = "BLOCKED" if value is None else ("PASS" if value <= maximum else "FAIL")
        results.append({"gate": name, "status": status, "value": value, "maximum": maximum})
    decision = "FAIL" if any(item["status"] == "FAIL" for item in results) else (
        "BLOCKED" if any(item["status"] == "BLOCKED" for item in results) else "PASS"
    )
    return {"status": decision, "gates": results}
