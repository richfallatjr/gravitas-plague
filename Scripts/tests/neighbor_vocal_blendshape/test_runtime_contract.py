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


class NeighborVocalBlendShapeRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[3]
        cls.paths = ToolPaths.discover(cls.root, profile=NEIGHBOR_PROFILE)

    def test_all_profiles_and_dad_default_remain_exact(self):
        self.assertEqual(ToolPaths.discover(self.root).profile, DAD_PROFILE)
        self.assertEqual(PROFILES, {
            "dad": DAD_PROFILE,
            "grandma": GRANDMA_PROFILE,
            "spouse": SPOUSE_PROFILE,
            "biker": BIKER_PROFILE,
            "neighbor": NEIGHBOR_PROFILE,
        })

    def test_neighbor_source_locks_lattice_donor_to_neighbor_output(self):
        source = load_source_descriptor(self.paths.source_descriptor, NEIGHBOR_PROFILE)
        self.assertEqual(source["donorBlendShapeName"], "Lattice")
        self.assertEqual(source["blendShapeName"], "neighborVocalClose")

        without_mapping = dict(source)
        without_mapping.pop("donorBlendShapeName")
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "source.json"
            path.write_text(json.dumps(without_mapping), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "donor blendshape name"):
                load_source_descriptor(path, NEIGHBOR_PROFILE)

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
        descriptor_data = self.paths.runtime_descriptor.read_bytes()
        self.assertEqual(
            hashlib.sha256(descriptor_data).hexdigest(),
            "f6ba722a0194efa92ac4619aac99d56f2bcf3578c471a0d098ff85d37ab90076",
        )
        descriptor = json.loads(descriptor_data)
        self.assertEqual(descriptor["schemaVersion"], 1)
        self.assertEqual(
            descriptor["descriptorID"],
            "neighbor.infected.vocalBlendShape.v1",
        )
        self.assertEqual(descriptor["characterID"], "neighbor")
        self.assertEqual(descriptor["sourceAssetResourceName"], "neighbor_biped")
        self.assertEqual(descriptor["sourceAssetExtension"], "usdz")
        self.assertEqual(
            descriptor["sourceAssetSHA256"],
            "f38dba681edb1e4af2452d0f90c8801cd4bc03ad4b84e6e4f69220d3ac2b9636",
        )
        self.assertEqual(descriptor["blendShapeName"], "neighborVocalClose")
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
            "neighbor_infected_vocal_blendshape_offsets.bin",
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
        self.assertEqual(point_count, 81_816)
        self.assertEqual(record_count, 624)
        self.assertEqual(reserved, 0)
        self.assertEqual(len(data), 17_530)
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
            "a73e00131328fe3f9a49ba64bdb01bfd6983ec566df96272e973acb300af4758",
        )
        self.assertEqual(descriptor["offsetPayloadMeshCount"], mesh_count)
        self.assertEqual(descriptor["offsetPayloadRecordCount"], record_count)
        self.assertEqual(descriptor["offsetPayloadSHA256"], payload_digest)

        with zipfile.ZipFile(self.paths.base_asset) as archive:
            names = archive.namelist()
        self.assertFalse(any("mouth_closed" in name for name in names))
        self.assertIn("textures/neighbor_biped_ior.png", names)

    def test_report_proves_explicit_donor_resolution_and_output_target(self):
        report = json.loads(
            self.paths.validation_report.read_text(encoding="utf-8")
        )
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(report["characterID"], "neighbor")
        self.assertFalse(report["donorBundled"])
        self.assertEqual(
            report["baseAssetSHA256Before"],
            "a00b04763770c5ad37d92b4c789a82caca46d8ecca87694b206ae2162b5cced7",
        )
        self.assertEqual(
            report["donorAssetSHA256"],
            "bc99e2560a33288a96ae25ba846e6b182f5265ed241a91d026c28c64cc1ae124",
        )
        mesh = report["validation"]["meshes"][0]
        self.assertEqual(
            mesh["baseTopologySHA256"],
            "526475526eafda965e5dd77f728e37881ceca2f5d9a8c3fe4dd69749456799bb",
        )
        self.assertEqual(mesh["donorTargetSource"], "boundBlendShape")
        self.assertEqual(
            mesh["donorBlendShapePrimPath"],
            "/root/Armature/char1/char1/Lattice",
        )
        self.assertEqual(mesh["donorBlendShapeOffsetRecordCount"], 81_816)
        self.assertEqual(mesh["donorBlendShapeNonzeroOffsetRecordCount"], 616)
        self.assertEqual(mesh["changedPointCount"], 624)
        self.assertAlmostEqual(
            mesh["worldDisplacementMeters"]["maximum"],
            0.04241730166635945,
        )
        authored = report["authoredAsset"]["authored"][0]
        self.assertEqual(authored["blendShapeName"], "neighborVocalClose")
        self.assertEqual(
            authored["blendShapePrimPath"],
            "/root/Armature/char1/char1_neighborVocalClose",
        )


if __name__ == "__main__":
    unittest.main()
