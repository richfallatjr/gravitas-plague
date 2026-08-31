import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Scripts/mind_eye_projection"))
import publish_projection_union_mask as publisher


class ProjectionUnionMaskPublisherTests(unittest.TestCase):
    def test_camera_space_union_mask_is_retired_from_runtime(self):
        runtime = ROOT / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection"
        profile_path = runtime / "profiles/angel_head_v1.json"
        manifest_path = runtime / "plates/angel_head_v1/source-manifest.json"
        profile = json.loads(profile_path.read_text())
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(profile["schemaVersion"], 2)
        self.assertNotIn("projectionMaskResourcePath", profile)
        self.assertNotIn("projectionMaskSHA256", profile)
        self.assertNotIn("projectionMask", manifest)
        self.assertEqual(
            profile["projectionReceiverUVMask"]["convention"],
            "darkProjectsLightSuppresses",
        )
        with self.assertRaisesRegex(SystemExit, "authoring-only"):
            publisher.main()


if __name__ == "__main__":
    unittest.main()
