import hashlib
import json
import struct
import unittest
import zipfile
from pathlib import Path


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
            ["presence_loop", "damage_hits", "death"],
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
        self.assertEqual(descriptor["offsetPayloadRecordCount"], 2004)
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            descriptor["offsetPayloadSHA256"],
        )

    def test_production_package_does_not_embed_complete_donor(self):
        with zipfile.ZipFile(self.asset_path) as archive:
            names = archive.namelist()
        self.assertFalse(any("mouth_closed" in name for name in names))


if __name__ == "__main__":
    unittest.main()
