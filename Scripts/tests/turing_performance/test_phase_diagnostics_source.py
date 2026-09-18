import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "verify_qwen_phase_diagnostics", ROOT / "scripts/turing/verify_qwen_phase_diagnostics.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class PhaseDiagnosticsSourceTests(unittest.TestCase):
    def test_opt_in_bounded_reachable_and_no_extra_materialization(self):
        self.assertEqual(MODULE.verify(ROOT), [])


if __name__ == "__main__":
    unittest.main()
