from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

from .report_schema import CONFIGURATIONS, FEATURE_MODES, SCENARIOS


def load_matrix(file_path: Path) -> dict[str, Any]:
    with file_path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    errors = validate_matrix(value)
    if errors:
        raise ValueError("; ".join(errors))
    return value


def validate_matrix(document: Any) -> list[str]:
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        return ["matrix schemaVersion must equal 1"]
    errors: list[str] = []
    if document.get("matrixVersion") != "mind-eye-release-matrix/1":
        errors.append("matrixVersion is unsupported")
    runs = document.get("requiredRuns")
    if not isinstance(runs, list) or not runs:
        return errors + ["requiredRuns must be a nonempty array"]
    seen: set[tuple[str, str, str]] = set()
    for index, item in enumerate(runs):
        if not isinstance(item, dict):
            errors.append(f"requiredRuns[{index}] must be an object")
            continue
        key = (item.get("scenario"), item.get("configuration"), item.get("featureMode"))
        if key[0] not in SCENARIOS or key[1] not in CONFIGURATIONS or key[2] not in FEATURE_MODES:
            errors.append(f"requiredRuns[{index}] contains an unknown enum value")
        if key in seen:
            errors.append(f"requiredRuns[{index}] is duplicated")
        seen.add(key)
        repetitions = item.get("minimumRepetitions")
        if not isinstance(repetitions, int) or isinstance(repetitions, bool) or repetitions < 1:
            errors.append(f"requiredRuns[{index}].minimumRepetitions must be positive")
    return errors


def evaluate_matrix(reports: Iterable[dict[str, Any]], matrix: dict[str, Any]) -> dict[str, Any]:
    modes_by_scenario: dict[str, set[str]] = {}
    for requirement in matrix["requiredRuns"]:
        modes_by_scenario.setdefault(requirement["scenario"], set()).add(
            requirement["featureMode"]
        )
    counts: Counter[tuple[str, str, str]] = Counter()
    for report in reports:
        run = report.get("run", {})
        mode = report.get("featureMode") or report.get("metadata", {}).get("featureMode")
        if mode is None:
            scenario_modes = modes_by_scenario.get(run.get("scenario"), set())
            if len(scenario_modes) == 1:
                mode = next(iter(scenario_modes))
        counts[(run.get("scenario"), run.get("configuration"), mode)] += 1
    rows = []
    for requirement in matrix["requiredRuns"]:
        key = (
            requirement["scenario"], requirement["configuration"],
            requirement["featureMode"],
        )
        actual = counts[key]
        required = requirement["minimumRepetitions"]
        rows.append({**requirement, "actualRepetitions": actual, "status": "PASS" if actual >= required else "BLOCKED"})
    return {"status": "PASS" if all(row["status"] == "PASS" for row in rows) else "BLOCKED", "runs": rows}
