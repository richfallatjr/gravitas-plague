import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts/turing/analyze_turing_residency_memory.py"
SPEC = importlib.util.spec_from_file_location("analyze_turing_residency_memory", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class ResidencyMemoryAnalysisTests(unittest.TestCase):
    def test_computes_second_lane_delta_from_medians(self):
        document = {
            "mode": "sharedImmutableFresh2",
            "memorySamples": [
                {"label": "lane0.afterEngine", "physicalFootprintMB": 100},
                {"label": "lane1.afterEngine", "physicalFootprintMB": 125},
            ],
        }
        result = MODULE.analyze([document])
        self.assertEqual(result["secondLaneIncrementalFootprintMB"], 25)
        self.assertFalse(result["hasRequiredDeviceBoundaries"])


if __name__ == "__main__":
    unittest.main()
