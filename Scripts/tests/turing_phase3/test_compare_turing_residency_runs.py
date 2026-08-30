import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT_ROOT = ROOT / "Scripts/turing"
sys.path.insert(0, str(SCRIPT_ROOT))
SCRIPT = SCRIPT_ROOT / "compare_turing_residency_runs.py"
SPEC = importlib.util.spec_from_file_location("compare_turing_residency_runs", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class ResidencyComparisonTests(unittest.TestCase):
    def run_document(self, seed=7):
        return {
            "mode": "independentFresh2",
            "qualificationIdentity": {
                "textHash": "abc",
                "seed": seed,
                "voiceID": "big_mike",
                "variantID": "default",
                "admissionMode": "currentOverlap",
                "commandBufferProfile": "operations40Megabytes32",
                "worldQualificationMode": "battle",
            },
            "residencyOwnership": {"actualLaneCount": 2},
            "memorySamples": [],
            "outputParity": True,
        }

    def test_rejects_mismatched_experiment_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary) / "a.json"
            second = Path(temporary) / "b.json"
            first.write_text(json.dumps(self.run_document(seed=7)))
            second.write_text(json.dumps(self.run_document(seed=8)))
            with self.assertRaises(ValueError):
                MODULE.compare([first, second])


if __name__ == "__main__":
    unittest.main()
