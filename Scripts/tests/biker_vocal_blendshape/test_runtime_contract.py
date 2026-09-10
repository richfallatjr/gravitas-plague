import hashlib
import json
import math
import struct
import sys
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from Scripts.dad_vocal_blendshape.paths import ToolPaths
from Scripts.dad_vocal_blendshape.profiles import (
    BIKER_PROFILE,
    DAD_PROFILE,
    GRANDMA_PROFILE,
    NEIGHBOR_PROFILE,
    PROFILES,
    SPOUSE_PROFILE,
)
from Scripts.dad_vocal_blendshape.validation import (
    _resolve_donor_target,
    load_source_descriptor,
)


class BikerVocalBlendShapeRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[3]
        cls.paths = ToolPaths.discover(cls.root, profile=BIKER_PROFILE)

    def test_existing_profiles_and_dad_default_remain_exact(self):
        self.assertEqual(ToolPaths.discover(self.root).profile, DAD_PROFILE)
        self.assertEqual(PROFILES, {
            "dad": DAD_PROFILE,
            "grandma": GRANDMA_PROFILE,
            "spouse": SPOUSE_PROFILE,
            "biker": BIKER_PROFILE,
            "neighbor": NEIGHBOR_PROFILE,
        })
        expected = {
            "dad_biped.usdz": (
                "a08f6f72f563c6e4e29610e7f591832ab45a2f3861ea3226555fc1de80db5aeb"
            ),
            "grandma_biped.usdz": (
                "c5847e8fe9e4df8e433a31c4492a72f0ea4fcc68d6f910efc68d08fb32bde002"
            ),
            "spouse_biped.usdz": (
                "e3e7d01d4dab7e63b8fce498b3d1b76c28c1f35a98049c6672507ee3fe7e4f67"
            ),
            "dad_infected_vocal_blendshape_offsets.bin": (
                "ed02b06b87f8d5d456a15a38543a9b5d409a277283ab1ec9b990658b8b9b530d"
            ),
            "grandma_infected_vocal_blendshape_offsets.bin": (
                "0df8b0f379ca071576dfaa7de3d044e9a0218fe5624242bfb10e424e0813d33b"
            ),
            "spouse_infected_vocal_blendshape_offsets.bin": (
                "376f4b44188f4250e82767f4d57617b280ea2522115209c196f5d193e102977f"
            ),
        }
        performance = self.root / (
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance"
        )
        for name, digest in expected.items():
            path = self.root / name if name.endswith(".usdz") else performance / name
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

    def test_biker_source_locks_lattice_donor_to_biker_output(self):
        source = load_source_descriptor(self.paths.source_descriptor, BIKER_PROFILE)
        self.assertEqual(source["donorBlendShapeName"], "Lattice")
        self.assertEqual(source["blendShapeName"], "bikerVocalClose")

        without_mapping = dict(source)
        without_mapping.pop("donorBlendShapeName")
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "source.json"
            path.write_text(json.dumps(without_mapping), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "donor blendshape name"):
                load_source_descriptor(path, BIKER_PROFILE)

    def test_required_donor_target_never_falls_back_to_mesh_points(self):
        class Attribute:
            def Get(self):
                return ["SomeOtherShape"]

        class Relationship:
            def GetTargets(self):
                return ["/unused/target"]

        class Binding:
            def GetBlendShapesAttr(self):
                return Attribute()

            def GetBlendShapeTargetsRel(self):
                return Relationship()

        fake_pxr = types.ModuleType("pxr")
        fake_pxr.UsdSkel = types.SimpleNamespace(BindingAPI=lambda _: Binding())
        stage = types.SimpleNamespace(GetPrimAtPath=lambda _: object())
        with patch.dict(sys.modules, {"pxr": fake_pxr}):
            with self.assertRaisesRegex(
                ValueError,
                "required donor blendshape Lattice is missing",
            ):
                _resolve_donor_target(
                    stage,
                    "/root/Armature/char1/char1",
                    "Lattice",
                    [(0, 0, 0)],
                    1e-6,
                    require_blend_shape=True,
                )

    def test_generated_descriptor_payload_and_asset_contract(self):
        descriptor = json.loads(
            self.paths.runtime_descriptor.read_text(encoding="utf-8")
        )
        self.assertEqual(descriptor["schemaVersion"], 1)
        self.assertEqual(
            descriptor["descriptorID"],
            "biker.infected.vocalBlendShape.v1",
        )
        self.assertEqual(descriptor["characterID"], "biker")
        self.assertEqual(descriptor["sourceAssetResourceName"], "biker_biped")
        self.assertEqual(descriptor["blendShapeName"], "bikerVocalClose")
        self.assertEqual(descriptor["basePose"], "wide")
        self.assertEqual(descriptor["poseWeights"], {
            "rest": 1.0,
            "small": 0.5,
            "wide": 0.0,
            "round": 0.5,
            "teeth": 1.0,
        })
        self.assertEqual(
            descriptor["audioRoles"],
            ["presence_loop", "damage_hits", "death"],
        )
        self.assertEqual(
            descriptor["offsetPayloadResourcePath"],
            "CharacterLibrary/FacialPerformance/"
            "biker_infected_vocal_blendshape_offsets.bin",
        )
        self.assertEqual(
            hashlib.sha256(self.paths.base_asset.read_bytes()).hexdigest(),
            descriptor["sourceAssetSHA256"],
        )

        data = self.paths.runtime_offsets.read_bytes()
        self.assertEqual(data[:8], b"GRDADV1\0")
        schema, mesh_count = struct.unpack_from("<II", data, 8)
        self.assertEqual((schema, mesh_count), (1, 1))
        path_length, point_count, record_count, reserved = struct.unpack_from(
            "<IIII", data, 16
        )
        path_start = 32
        path_end = path_start + path_length
        self.assertEqual(
            data[path_start:path_end].decode("utf-8"),
            "/root/Armature/char1/char1",
        )
        self.assertEqual(point_count, 83_891)
        self.assertEqual(record_count, 878)
        self.assertEqual(reserved, 0)
        self.assertEqual(len(data), 24_642)
        record = struct.Struct("<Iffffff")
        cursor = path_end
        previous = -1
        for _ in range(record_count):
            values = record.unpack_from(data, cursor)
            cursor += record.size
            index = values[0]
            offset = values[4:7]
            self.assertGreater(index, previous)
            self.assertLess(index, point_count)
            self.assertTrue(all(math.isfinite(value) for value in values[1:]))
            self.assertGreater(sum(value * value for value in offset), 0)
            previous = index
        self.assertEqual(cursor, len(data))
        payload_digest = hashlib.sha256(data).hexdigest()
        self.assertEqual(
            payload_digest,
            "40ac54b9a30ede50581d585106ae7f8b659b805cb63fa1557296937636715548",
        )
        self.assertEqual(descriptor["offsetPayloadMeshCount"], mesh_count)
        self.assertEqual(descriptor["offsetPayloadRecordCount"], record_count)
        self.assertEqual(descriptor["offsetPayloadSHA256"], payload_digest)

        with zipfile.ZipFile(self.paths.base_asset) as archive:
            names = archive.namelist()
        self.assertFalse(any("mouth_closed" in name for name in names))
        self.assertIn("textures/biker_biped_ior.png", names)

    def test_report_proves_explicit_donor_resolution_and_output_target(self):
        report = json.loads(
            self.paths.validation_report.read_text(encoding="utf-8")
        )
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(report["characterID"], "biker")
        self.assertFalse(report["donorBundled"])
        self.assertEqual(
            report["baseAssetSHA256Before"],
            "8a77d969d891bfcae8ea9deb0dc8b4e3d5c7965d854bc042bf1e456da762a848",
        )
        self.assertEqual(
            report["donorAssetSHA256"],
            "45dee65184bd91d64d3f8cc1f3a0ba3236d7da4bfeed9b1d50e87a26c396fe08",
        )
        mesh = report["validation"]["meshes"][0]
        self.assertEqual(
            mesh["baseTopologySHA256"],
            "c6602c8f37214ff3594038ddf4d6f877c60625b6d31479284897694a0e16972b",
        )
        self.assertEqual(mesh["donorTargetSource"], "boundBlendShape")
        self.assertEqual(
            mesh["donorBlendShapePrimPath"],
            "/root/Armature/char1/char1/Lattice",
        )
        self.assertEqual(mesh["donorBlendShapeOffsetRecordCount"], 83_891)
        self.assertEqual(mesh["donorBlendShapeNonzeroOffsetRecordCount"], 848)
        self.assertEqual(mesh["changedPointCount"], 878)
        self.assertAlmostEqual(
            mesh["worldDisplacementMeters"]["maximum"],
            0.04106945339641521,
        )
        authored = report["authoredAsset"]["authored"][0]
        self.assertEqual(authored["blendShapeName"], "bikerVocalClose")
        self.assertEqual(
            authored["blendShapePrimPath"],
            "/root/Armature/char1/char1_bikerVocalClose",
        )


if __name__ == "__main__":
    unittest.main()
