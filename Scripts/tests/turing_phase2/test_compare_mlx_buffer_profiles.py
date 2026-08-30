import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[2] / "turing"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location(
    "compare_mlx_buffer_profiles", SCRIPT_DIR / "compare_mlx_buffer_profiles.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class ComparisonTests(unittest.TestCase):
    def test_failure_free_profile_ranks_first(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for name, failed in (("safe", False), ("failed", True)):
                path = Path(directory) / f"{name}.json"
                path.write_text(json.dumps({
                    "profile": name,
                    "admissionMode": "currentOverlap",
                    "recentRecords": [{
                        "sequence": 1,
                        "GPUSeconds": 0.02 if not failed else 0.01,
                        "isFailure": failed,
                    }],
                }), encoding="utf-8")
                paths.append(path)
            self.assertEqual(MODULE.compare(paths)[0]["profile"], "safe")


if __name__ == "__main__":
    unittest.main()
