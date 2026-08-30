import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Scripts/turing/verify_turing_shared_residency.py"
SPEC = importlib.util.spec_from_file_location("verify_turing_shared_residency", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class SharedResidencySourceAuditTests(unittest.TestCase):
    def test_repository_passes_phase3_source_audit(self):
        self.assertEqual(MODULE.verify(ROOT), [])


if __name__ == "__main__":
    unittest.main()
