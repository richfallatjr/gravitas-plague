from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .archive_audit import audit_archive
from .built_bundle_audit import audit_built_app, find_unique_app
from .compare_runs import compare_control, compare_qwen
from .final_report import final_decision, manual_review_template, write_final_report
from .release_budget import evaluate_budget, load_budget
from .release_matrix import evaluate_matrix, load_matrix
from .report_validator import load_json, validate_directory, validate_report_file
from .source_audit import audit_source
from .thinning_report import parse_thinning_report

EXIT_SCHEMA = 1
EXIT_MISSING_SCENARIO = 2
EXIT_MEMORY = 3
EXIT_PERFORMANCE = 4
EXIT_BUNDLE = 5
EXIT_MANUAL = 6
EXIT_STABILITY = 7
EXIT_BLOCKED = 8
EXIT_INTERNAL = 9


def _emit(value: Any, output: Path | None = None) -> None:
    encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")


def _reports(directory: Path) -> list[dict[str, Any]]:
    return [load_json(item) for item in sorted(directory.glob("*.qualification.json"))]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Mind's Eye release qualification")
    commands = result.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-report")
    validate.add_argument("report", type=Path)
    validate = commands.add_parser("validate-directory")
    validate.add_argument("directory", type=Path)
    compare = commands.add_parser("compare-control")
    compare.add_argument("--control-directory", type=Path, required=True)
    compare.add_argument("--enabled-directory", type=Path, required=True)
    compare.add_argument("--kind", choices=("story", "qwen"), default="story")
    budget = commands.add_parser("evaluate-budget")
    budget.add_argument("measurements", type=Path)
    budget.add_argument("--budget", type=Path, required=True)
    source = commands.add_parser("audit-source")
    source.add_argument("--repository-root", type=Path, default=Path.cwd())
    built = commands.add_parser("audit-built-app")
    built.add_argument("--repository-root", type=Path, default=Path.cwd())
    built.add_argument("--app", type=Path)
    built.add_argument("--search-root", type=Path)
    archive = commands.add_parser("audit-archive")
    archive.add_argument("--repository-root", type=Path, default=Path.cwd())
    archive.add_argument("--archive", type=Path, required=True)
    thinning = commands.add_parser("parse-thinning-report")
    thinning.add_argument("report", type=Path)
    summary = commands.add_parser("build-summary")
    summary.add_argument("--reports", type=Path, required=True)
    summary.add_argument("--matrix", type=Path, required=True)
    summary.add_argument("--output", type=Path)
    final = commands.add_parser("final-decision")
    final.add_argument("--inputs", type=Path, required=True)
    final.add_argument("--output-directory", type=Path, required=True)
    template = commands.add_parser("manual-review-template")
    template.add_argument("--output", type=Path, required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "validate-report":
            result = validate_report_file(arguments.report)
            _emit(result)
            return 0 if result["status"] == "PASS" else EXIT_SCHEMA
        if arguments.command == "validate-directory":
            result = validate_directory(arguments.directory)
            _emit(result)
            return 0 if result["status"] == "PASS" else EXIT_SCHEMA
        if arguments.command == "compare-control":
            control = _reports(arguments.control_directory)
            enabled = _reports(arguments.enabled_directory)
            result = compare_qwen(control, enabled) if arguments.kind == "qwen" else compare_control(control, enabled)
            _emit(result)
            return 0
        if arguments.command == "evaluate-budget":
            result = evaluate_budget(load_json(arguments.measurements), load_budget(arguments.budget))
            _emit(result)
            return {"PASS": 0, "BLOCKED": EXIT_BLOCKED, "FAIL": EXIT_MEMORY}[result["status"]]
        if arguments.command == "audit-source":
            result = audit_source(arguments.repository_root)
            _emit(result)
            return 0 if result["status"] == "PASS" else EXIT_BUNDLE
        if arguments.command == "audit-built-app":
            app = arguments.app or find_unique_app(arguments.search_root)
            result = audit_built_app(arguments.repository_root, app)
            _emit(result)
            return 0 if result["status"] == "PASS" else EXIT_BUNDLE
        if arguments.command == "audit-archive":
            result = audit_archive(arguments.repository_root, arguments.archive)
            _emit(result)
            return 0 if result["status"] == "PASS" else EXIT_BUNDLE
        if arguments.command == "parse-thinning-report":
            result = parse_thinning_report(arguments.report)
            _emit(result)
            return 0 if result["status"] == "PASS" else EXIT_BUNDLE
        if arguments.command == "build-summary":
            reports = _reports(arguments.reports)
            result = evaluate_matrix(reports, load_matrix(arguments.matrix))
            _emit(result, arguments.output)
            return 0 if result["status"] == "PASS" else EXIT_MISSING_SCENARIO
        if arguments.command == "final-decision":
            result = final_decision(load_json(arguments.inputs))
            paths = write_final_report(arguments.output_directory, result)
            _emit({**result, "outputs": [str(item) for item in paths]})
            return {"PASS": 0, "BLOCKED": EXIT_BLOCKED, "FAIL": EXIT_STABILITY}[result["decision"]]
        if arguments.command == "manual-review-template":
            _emit(manual_review_template(), arguments.output)
            return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        _emit({"status": "FAIL", "error": str(error)})
        return EXIT_SCHEMA
    except Exception as error:
        _emit({"status": "FAIL", "error": str(error), "kind": type(error).__name__})
        return EXIT_INTERNAL
    return EXIT_INTERNAL


if __name__ == "__main__":
    raise SystemExit(main())
