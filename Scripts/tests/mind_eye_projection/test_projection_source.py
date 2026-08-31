import copy
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[3]

import sys
sys.path.insert(0, str(ROOT / "Scripts/mind_eye_projection"))
import validate_projection_source as validator


class ProjectionSourceValidatorTests(unittest.TestCase):
    def test_repository_package_is_fail_closed_until_parity_passes(self):
        qualification = validator.load_json(
            ROOT / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/qualification/angel_head_v1.material-parity.json"
        )
        if qualification["passed"]:
            report = validator.validate(ROOT)
            self.assertEqual(report["status"], "PASS")
            self.assertEqual(report["plateCount"], 9)
            self.assertIn("teeth", report["mouthFamilies"])
        else:
            with self.assertRaisesRegex(ValueError, "parity is not qualified"):
                validator.validate(ROOT)

    def test_missing_teeth_is_rejected(self):
        original = validator.load_json

        def without_teeth(path):
            value = original(path)
            if path.name == "source-manifest.json":
                value = copy.deepcopy(value)
                value["mouths"]["teeth"] = []
            return value

        with mock.patch.object(validator, "load_json", side_effect=without_teeth):
            with self.assertRaisesRegex(ValueError, "family is empty"):
                validator.validate(ROOT)

    def test_stale_hash_is_rejected(self):
        original = validator.load_json

        def stale_profile(path):
            value = original(path)
            if path.name == "source-manifest.json":
                value = copy.deepcopy(value)
                value["profileSHA256"] = "0" * 64
            return value

        with mock.patch.object(validator, "load_json", side_effect=stale_profile):
            with self.assertRaisesRegex(ValueError, "profileSHA256 is stale"):
                validator.validate(ROOT)


if __name__ == "__main__":
    unittest.main()
