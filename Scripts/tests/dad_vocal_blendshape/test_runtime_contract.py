import hashlib
import json
import struct
import unittest
import zipfile
from pathlib import Path

from Scripts.dad_vocal_blendshape.validation import apply_blend_shape_offsets


class DadVocalBlendShapeRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[3]
        cls.performance = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance"
        )
        cls.descriptor_path = (
            cls.performance / "dad_infected_vocal_blendshape.json"
        )
        cls.payload_path = (
            cls.performance / "dad_infected_vocal_blendshape_offsets.bin"
        )
        cls.validation_report_path = cls.root / (
            "Authoring/DadVocalBlendShape/Reports/"
            "dad_vocal_close.validation.json"
        )
        cls.asset_path = cls.root / "dad_biped.usdz"

    def test_locked_inverse_pose_mapping_and_identity(self):
        descriptor = json.loads(self.descriptor_path.read_text(encoding="utf-8"))
        self.assertEqual(descriptor["schemaVersion"], 1)
        self.assertEqual(
            descriptor["descriptorID"],
            "dad.infected.vocalBlendShape.v1",
        )
        self.assertEqual(descriptor["characterID"], "dad")
        self.assertEqual(descriptor["blendShapeName"], "dadVocalClose")
        self.assertEqual(descriptor["basePose"], "wide")
        self.assertEqual(descriptor["poseWeights"], {
            "rest": 1.0,
            "small": 0.5,
            "wide": 0.0,
            "round": 0.5,
            "teeth": 1.0,
        })
        self.assertEqual(descriptor["fallbackWeight"], 1.0)
        self.assertEqual(descriptor["allowedWeightRange"], [0.0, 1.0])
        self.assertEqual(
            descriptor["audioRoles"],
            ["damage_hits", "death"],
        )
        self.assertEqual(
            hashlib.sha256(self.asset_path.read_bytes()).hexdigest(),
            descriptor["sourceAssetSHA256"],
        )

    def test_dad_specific_sparse_payload_contract(self):
        descriptor = json.loads(self.descriptor_path.read_text(encoding="utf-8"))
        data = self.payload_path.read_bytes()
        self.assertEqual(data[:8], b"GRDADV1\0")
        schema, mesh_count = struct.unpack_from("<II", data, 8)
        self.assertEqual(schema, 1)
        self.assertEqual(mesh_count, 1)
        self.assertEqual(mesh_count, descriptor["offsetPayloadMeshCount"])
        path_length, point_count, record_count, reserved = struct.unpack_from(
            "<IIII",
            data,
            16,
        )
        self.assertGreater(path_length, 0)
        self.assertEqual(point_count, 144525)
        self.assertGreater(record_count, 0)
        self.assertEqual(reserved, 0)
        self.assertEqual(descriptor["offsetPayloadRecordCount"], record_count)
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            descriptor["offsetPayloadSHA256"],
        )

    def test_production_package_does_not_embed_complete_donor(self):
        with zipfile.ZipFile(self.asset_path) as archive:
            names = archive.namelist()
        self.assertFalse(any("mouth_closed" in name for name in names))

    def test_donor_dense_shape_key_resolves_full_target_points(self):
        base = [(0, 0, 0), (1, 1, 1), (2, 2, 2)]
        offsets = [(0, 1, 0), (0, 0, -0.5), (2, 0, 0)]
        expected = ((0, 1, 0), (1, 1, 0.5), (4, 2, 2))
        self.assertEqual(apply_blend_shape_offsets(base, offsets, None), expected)
        self.assertEqual(
            apply_blend_shape_offsets(base, offsets, [0, 1, 2]),
            expected,
        )

    def test_donor_sparse_shape_key_preserves_unaffected_points(self):
        base = [(0, 0, 0), (1, 1, 1), (2, 2, 2)]
        self.assertEqual(
            apply_blend_shape_offsets(base, [(0, -1, 0)], [1]),
            ((0, 0, 0), (1, 0, 1), (2, 2, 2)),
        )
        with self.assertRaisesRegex(ValueError, "duplicated"):
            apply_blend_shape_offsets(base, [(1, 0, 0), (0, 1, 0)], [1, 1])
        with self.assertRaisesRegex(ValueError, "out of range"):
            apply_blend_shape_offsets(base, [(1, 0, 0)], [3])

    def test_current_donor_uses_the_authored_close_shape_key(self):
        report = json.loads(
            self.validation_report_path.read_text(encoding="utf-8")
        )
        mesh = report["validation"]["meshes"][0]
        self.assertEqual(mesh["donorTargetSource"], "boundBlendShape")
        self.assertEqual(
            mesh["donorBlendShapePrimPath"],
            "/root/Armature/char1/char1/dadVocalClose",
        )
        self.assertEqual(mesh["donorBlendShapeOffsetRecordCount"], 144525)
        self.assertGreater(mesh["donorBlendShapeNonzeroOffsetRecordCount"], 0)
        descriptor = json.loads(self.descriptor_path.read_text(encoding="utf-8"))
        self.assertGreater(mesh["changedPointCount"], 0)
        self.assertEqual(
            mesh["changedPointCount"],
            descriptor["offsetPayloadRecordCount"],
        )


if __name__ == "__main__":
    unittest.main()
