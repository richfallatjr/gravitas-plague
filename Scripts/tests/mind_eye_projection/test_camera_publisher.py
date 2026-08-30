import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
PROJECTION = ROOT / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection"


class CameraPublisherTests(unittest.TestCase):
    def test_publisher_preserves_exact_candidate_bytes(self):
        candidate = PROJECTION / "cameras/angel_head_v1.camera.json"
        with tempfile.TemporaryDirectory() as temporary:
            published = pathlib.Path(temporary) / "published.camera.json"
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "Scripts/mind_eye_projection/publish_projection_camera.py"),
                    "--candidate",
                    str(candidate),
                    "--target",
                    str(published),
                    "--profile",
                    str(PROJECTION / "profiles/angel_head_v1.json"),
                    "--target-descriptor",
                    str(PROJECTION / "targets/angel_head_v1.target.json"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(published.read_bytes(), candidate.read_bytes())


if __name__ == "__main__":
    unittest.main()
