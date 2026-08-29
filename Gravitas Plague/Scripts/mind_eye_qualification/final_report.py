from __future__ import annotations

import json
from enum import Enum
from pathlib import Path
from typing import Any


class Decision(str, Enum):
    PASS = "PASS"
    BLOCKED = "BLOCKED"
    FAIL = "FAIL"


REQUIRED_VISUAL_IDS = {
    "fixed-world-card", "no-head-following", "wall-parallel", "shelf-clearance",
    "bench-clearance", "handheld-selfie-read", "foreground-background-parallax",
    "grip-correction", "blink-natural", "mask-bright-room", "mask-dark-room",
    "mask-near-portal", "no-source-edges", "no-alpha-halo", "authored-rest",
    "authored-small", "authored-wide", "authored-round", "authored-teeth",
    "authored-scriptPoint05-independent", "generated-promptvoice",
    "generated-conversationvoice", "generated-gap-rest",
    "player-dictation-no-portrait", "rich-no-big-mike-substitution",
    "physical-mike-suppression", "inactive-resume", "background-no-resurrection",
}


def manual_review_status(review: Any) -> tuple[Decision, list[str]]:
    if not isinstance(review, dict):
        return Decision.BLOCKED, ["manual visual review is missing"]
    items = review.get("items")
    if not isinstance(items, list):
        return Decision.BLOCKED, ["manual visual review items are missing"]
    by_id = {item.get("id"): item.get("status") for item in items if isinstance(item, dict)}
    missing = sorted(REQUIRED_VISUAL_IDS - by_id.keys())
    if missing:
        return Decision.BLOCKED, ["missing manual review items: " + ", ".join(missing)]
    failed = sorted(item_id for item_id, status in by_id.items() if status == "fail")
    not_run = sorted(item_id for item_id in REQUIRED_VISUAL_IDS if by_id.get(item_id) != "pass")
    if failed:
        return Decision.FAIL, ["failed manual review items: " + ", ".join(failed)]
    if not_run:
        return Decision.BLOCKED, ["manual review not run: " + ", ".join(not_run)]
    if not review.get("reviewer") or not review.get("device") or not review.get("visionOS"):
        return Decision.BLOCKED, ["manual review identity/device fields are incomplete"]
    return Decision.PASS, []


def final_decision(inputs: dict[str, Any]) -> dict[str, Any]:
    evidence = []
    hard_failures = []
    blockers = []
    for name in (
        "sourceAudit", "builtAppAudit", "archiveAudit", "thinningAudit",
        "reportValidation", "budgetEvaluation", "automatedTests",
        "crashTerminationRecords",
    ):
        value = inputs.get(name)
        status = value.get("status") if isinstance(value, dict) else None
        evidence.append({"gate": name, "status": status or "BLOCKED"})
        if status == "FAIL":
            hard_failures.append(name)
        elif status != "PASS":
            blockers.append(name)
    matrix = inputs.get("matrixEvaluation")
    matrix_status = matrix.get("status") if isinstance(matrix, dict) else None
    evidence.append({"gate": "releaseMatrix", "status": matrix_status or "BLOCKED"})
    if matrix_status == "FAIL":
        hard_failures.append("releaseMatrix")
    elif matrix_status != "PASS":
        blockers.append("releaseMatrix")
    visual_decision, visual_notes = manual_review_status(inputs.get("manualVisualReview"))
    evidence.append({"gate": "manualVisualReview", "status": visual_decision.value})
    if visual_decision is Decision.FAIL:
        hard_failures.append("manualVisualReview")
    elif visual_decision is Decision.BLOCKED:
        blockers.append("manualVisualReview")
    if inputs.get("testFlightActual") is not True:
        blockers.append("actualTestFlight")
        evidence.append({"gate": "actualTestFlight", "status": "BLOCKED"})
    decision = Decision.FAIL if hard_failures else (Decision.BLOCKED if blockers else Decision.PASS)
    return {
        "schemaVersion": 1,
        "reportVersion": "mind-eye-final-qualification/1",
        "decision": decision.value,
        "hardFailures": sorted(set(hard_failures)),
        "blockers": sorted(set(blockers)),
        "manualReviewNotes": visual_notes,
        "evidence": evidence,
        "gateDetails": {
            key: value for key, value in sorted(inputs.items())
            if key != "manualVisualReview"
        },
    }


def write_final_report(output_directory: Path, result: dict[str, Any]) -> tuple[Path, Path]:
    output_directory.mkdir(parents=True, exist_ok=True)
    json_path = output_directory / "MindEye_Final_Qualification.json"
    markdown_path = output_directory / "MindEye_Final_Qualification.md"
    json_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    status_by_gate = {
        item["gate"]: item["status"] for item in result.get("evidence", [])
    }
    lines = [
        "# Mind’s Eye Final Qualification",
        "",
        f"Decision: **{result['decision']}**",
        "",
        "## Blockers",
        "",
    ]
    lines.extend(f"- {item}" for item in result.get("blockers", []))
    if not result.get("blockers"):
        lines.append("- None")
    lines.extend(["", "## Hard failures", ""])
    lines.extend(f"- {item}" for item in result.get("hardFailures", []))
    if not result.get("hardFailures"):
        lines.append("- None")
    lines.extend([
        "",
        "## Qualification configurations",
        "",
        "- Release control, no debugger: required by the release matrix.",
        "- Release enabled, no debugger: required by the release matrix.",
        "- Xcode debugger and video-capture runs: separate required evidence.",
        "- Actual TestFlight: " + status_by_gate.get("actualTestFlight", "BLOCKED") + ".",
        "",
        "## Memory",
        "",
        "- Budget evaluation: " + status_by_gate.get("budgetEvaluation", "BLOCKED") + ".",
        "- Control, cold package, active portrait, Qwen overlap, dismissal, second-run, and ten-cycle measurements are accepted only from validated physical-device reports.",
        "- Ownership after teardown is validated per recorded checkpoint.",
        "",
        "## Conditional residency optimization",
        "",
        "- Packed-layer policy remains disabled unless measured device memory fails the baseline gate and pixel-parity evidence passes.",
        "- Canonical full-canvas source art remains the source contract; full and packed duplicates may not ship.",
        "",
        "## CPU, GPU, and frame timing",
        "",
        "- Motion, authored, generated, compositor encode, compositor GPU, frame cadence, and clamp metrics are emitted by the qualification-only runtime.",
        "- Performance budgets: " + status_by_gate.get("budgetEvaluation", "BLOCKED") + ".",
        "",
        "## Audio-start latency",
        "",
        "- Audible-start observation is subscribed globally in both control and enabled qualification modes.",
        "- Mind’s Eye package loading, authored-track loading, and generated analysis are not awaited by audio start.",
        "- Control-versus-enabled P95 comparison: " + status_by_gate.get("releaseMatrix", "BLOCKED") + ".",
        "",
        "## Lifecycle and teardown",
        "",
        "- Reports cover pause/resume, backgrounding, pressure, Qwen preflight, reset, operation-mode teardown, shutdown, ownership, registries, leases, cards, and compositor work.",
        "- Release-matrix coverage: " + status_by_gate.get("releaseMatrix", "BLOCKED") + ".",
        "",
        "## Bundle and distribution",
        "",
        "- Source audit: " + status_by_gate.get("sourceAudit", "BLOCKED") + ".",
        "- Built-app audit: " + status_by_gate.get("builtAppAudit", "BLOCKED") + ".",
        "- Archive audit: " + status_by_gate.get("archiveAudit", "BLOCKED") + ".",
        "- App-thinning audit: " + status_by_gate.get("thinningAudit", "BLOCKED") + ".",
        "",
        "## Automated tests",
        "",
        "- Automated test gate: " + status_by_gate.get("automatedTests", "BLOCKED") + ".",
        "- Deterministic report/schema validation: " + status_by_gate.get("reportValidation", "BLOCKED") + ".",
        "- Crash and termination evidence: " + status_by_gate.get("crashTerminationRecords", "BLOCKED") + ".",
        "",
        "## Manual review",
        "",
        "- Vision Pro visual and stereo-comfort review: " + status_by_gate.get("manualVisualReview", "BLOCKED") + ".",
    ])
    lines.extend(
        f"- {note}" for note in result.get("manualReviewNotes", [])
    )
    lines.extend([
        "",
        "## Final contract",
        "",
        "- Required: audio is never delayed, paused, or stopped by Mind’s Eye.",
        "- Required: story progression and exact-speaker routing remain authoritative.",
        "- Required: runtime ownership is limited to one package and is measured through teardown.",
        "- Verified locally: active qualification controls and report writing are compiled out of the production Release build.",
        "- Release is approved only when every required gate is PASS.",
    ])
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return json_path, markdown_path


def manual_review_template() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "reviewVersion": "mind-eye-manual-visual-review/1",
        "reviewer": "",
        "device": "",
        "visionOS": "",
        "items": [
            {"id": item_id, "status": "notRun", "notes": ""}
            for item_id in sorted(REQUIRED_VISUAL_IDS)
        ],
    }
