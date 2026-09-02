import json
import hashlib
import struct
import unittest
from pathlib import Path


class RuntimeContractTests(unittest.TestCase):
    def test_locked_mapping_keeps_teeth_closed(self):
        root = Path(__file__).resolve().parents[3]
        descriptor = json.loads((root / (
            "Gravitas Plague/TuringResources/Turing/Chapter03/"
            "AngelProjection/angel_jaw_open_projection.json"
        )).read_text(encoding="utf-8"))
        self.assertEqual(descriptor["blendShapeName"], "jawOpenProjection")
        self.assertEqual(descriptor["poseWeights"], {
            "rest": 0.0,
            "small": 0.5,
            "wide": 1.0,
            "round": 0.5,
            "teeth": 0.0,
        })
        self.assertTrue(descriptor["requiresProjectionReady"])
        payload = root / (
            "Gravitas Plague/TuringResources/Turing/Chapter03/"
            "AngelProjection/angel_jaw_open_projection_offsets.bin"
        )
        data = payload.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), descriptor[
            "offsetPayloadSHA256"
        ])
        self.assertEqual(data[:8], b"GRJAWP1\0")
        schema, mesh_count = struct.unpack_from("<II", data, 8)
        self.assertEqual(schema, 1)
        self.assertEqual(mesh_count, descriptor["offsetPayloadMeshCount"])
        self.assertGreater(descriptor["offsetPayloadRecordCount"], 0)

    def test_projection_identity_chain_matches_current_angel(self):
        root = Path(__file__).resolve().parents[3]
        projection = root / (
            "Gravitas Plague/TuringResources/Turing/MindsEye/Projection"
        )
        subject = root / "angel_posed_01.usdz"
        profile = projection / "profiles/angel_head_v1.json"
        camera = projection / "cameras/angel_head_v1.camera.json"
        target = projection / "targets/angel_head_v1.target.json"
        contract = projection / "materials/angel_head_v1.pbr-binding.json"
        qualification = projection / (
            "qualification/angel_head_v1.material-parity.json"
        )
        manifest = json.loads((projection / (
            "plates/angel_head_v1/source-manifest.json"
        )).read_text(encoding="utf-8"))

        def digest(path):
            return hashlib.sha256(path.read_bytes()).hexdigest()

        identities = {
            "profileSHA256": digest(profile),
            "cameraSHA256": digest(camera),
            "targetSHA256": digest(target),
            "subjectAssetSHA256": digest(subject),
        }
        for field, expected in identities.items():
            self.assertEqual(manifest[field], expected)
        pbr = json.loads(contract.read_text(encoding="utf-8"))
        self.assertEqual(pbr["subjectAssetSHA256"], identities[
            "subjectAssetSHA256"
        ])
        parity = json.loads(qualification.read_text(encoding="utf-8"))
        for field, expected in identities.items():
            self.assertEqual(parity[field], expected)
        self.assertEqual(parity["importedPBRContractSHA256"], digest(contract))


if __name__ == "__main__":
    unittest.main()
