import hashlib
import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Scripts/mind_eye_projection"))
import publish_projection_union_mask as publisher


class ProjectionUnionMaskPublisherTests(unittest.TestCase):
    def test_published_runtime_contract_is_hash_bound(self):
        runtime = ROOT / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection"
        profile_path = runtime / "profiles/angel_head_v1.json"
        manifest_path = runtime / "plates/angel_head_v1/source-manifest.json"
        capture_manifest_path = (
            ROOT / "Authoring/MindEyeProjectionCaptures/angel_head_v1/"
            "angel_head_v1_capture-manifest.json"
        )
        profile = json.loads(profile_path.read_text())
        manifest = json.loads(manifest_path.read_text())
        capture = json.loads(capture_manifest_path.read_text())
        mask = ROOT / "Gravitas Plague/TuringResources" / profile[
            "projectionMaskResourcePath"
        ]
        mask_hash = hashlib.sha256(mask.read_bytes()).hexdigest()
        profile_hash = hashlib.sha256(profile_path.read_bytes()).hexdigest()

        self.assertEqual(publisher.png_contract(mask), (1440, 1440, 16, 0))
        self.assertEqual(profile["projectionMaskSHA256"], mask_hash)
        self.assertEqual(manifest["projectionMask"]["SHA256"], mask_hash)
        self.assertEqual(manifest["profileSHA256"], profile_hash)
        self.assertEqual(capture["profileSHA256"], profile_hash)


if __name__ == "__main__":
    unittest.main()
