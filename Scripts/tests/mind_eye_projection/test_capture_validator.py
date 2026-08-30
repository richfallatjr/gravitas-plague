import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "Scripts/mind_eye_projection/validate_projection_capture.py"


class CaptureValidatorTests(unittest.TestCase):
    def test_source_audit_passes(self):
        subprocess.run(
            [sys.executable, str(VALIDATOR), "--source-audit-only", "--repository-root", str(ROOT)],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_missing_capture_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR),
                    "--directory",
                    temporary,
                    "--runtime-camera",
                    str(ROOT / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json"),
                ],
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing or empty required output", result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
