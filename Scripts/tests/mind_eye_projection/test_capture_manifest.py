import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]


class CaptureManifestTests(unittest.TestCase):
    def test_inspector_reports_identity_and_outputs(self):
        payload = {
            "captureID": "angel_head_v1",
            "cameraSHA256": "abc",
            "maskCoverageFraction": 0.25,
            "maskBoundingBoxPixels": [1, 2, 3, 4],
            "outputs": [{"filename": "beauty.png"}],
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "manifest.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(ROOT / "Scripts/mind_eye_projection/inspect_capture_manifest.py"), str(path)],
                check=True,
                capture_output=True,
                text=True,
            )
        decoded = json.loads(result.stdout)
        self.assertEqual(decoded["captureID"], "angel_head_v1")
        self.assertEqual(decoded["outputs"], ["beauty.png"])


if __name__ == "__main__":
    unittest.main()
