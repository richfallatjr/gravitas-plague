import json
from pathlib import Path

from mind_eye_qualification.release_budget import evaluate_budget, load_budget


def test_budget_loads_and_missing_measurements_block():
    scripts = Path(__file__).resolve().parents[2]
    budget = load_budget(scripts / "mind_eye_qualification/config/release_budget.json")
    result = evaluate_budget({}, budget)
    assert result["status"] == "BLOCKED"


def test_budget_failure_is_not_relabeled_pass(tmp_path):
    scripts = Path(__file__).resolve().parents[2]
    budget = load_budget(scripts / "mind_eye_qualification/config/release_budget.json")
    result = evaluate_budget({"activeIncrementMiB": 193}, budget)
    assert result["status"] == "FAIL"
