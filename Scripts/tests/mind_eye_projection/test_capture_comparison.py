import pathlib
import json
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
COMPARISON = ROOT / "Scripts/mind_eye_projection/compare_projection_captures.py"
EXACT = (
    "angel_head_v1_camera.json",
    "angel_head_v1_projection-mask-linear16.png",
    "angel_head_v1_projection-mask-preview.png",
    "angel_head_v1_alignment-guide.png",
)


class CaptureComparisonTests(unittest.TestCase):
    def test_exact_contract_accepts_identity_and_rejects_difference(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = pathlib.Path(temporary) / "first"
            second = pathlib.Path(temporary) / "second"
            first.mkdir()
            second.mkdir()
            for filename in EXACT:
                (first / filename).write_bytes(b"same")
                (second / filename).write_bytes(b"same")
            ppm = b"P6\n1 1\n255\n\x20\x40\x60"
            for filename in (
                "angel_head_v1_scene-beauty.png",
                "angel_head_v1_face-beauty.png",
            ):
                (first / filename).write_bytes(ppm)
                (second / filename).write_bytes(ppm)
            manifest = {
                "profileSHA256": "profile",
                "targetSHA256": "target",
                "cameraSHA256": "camera",
            }
            for directory in (first, second):
                (directory / "angel_head_v1_capture-manifest.json").write_text(
                    json.dumps(manifest), encoding="utf-8"
                )
            subprocess.run(
                [sys.executable, str(COMPARISON), str(first), str(second)],
                check=True,
                capture_output=True,
                text=True,
            )
            (second / EXACT[0]).write_bytes(b"different")
            result = subprocess.run(
                [sys.executable, str(COMPARISON), str(first), str(second)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
