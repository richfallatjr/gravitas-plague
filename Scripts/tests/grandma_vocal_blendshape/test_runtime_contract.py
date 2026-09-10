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
from Scripts.dad_vocal_blendshape.profiles import DAD_PROFILE, GRANDMA_PROFILE
from Scripts.dad_vocal_blendshape.validation import (
    _resolve_donor_target,
    load_source_descriptor,
)


class GrandmaVocalBlendShapeRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[3]
        cls.paths = ToolPaths.discover(cls.root, profile=GRANDMA_PROFILE)

    def test_dad_remains_the_default_profile_and_paths(self):
        paths = ToolPaths.discover(self.root)
        self.assertEqual(paths.profile, DAD_PROFILE)
        self.assertEqual(paths.base_asset, self.root / "dad_biped.usdz")
        self.assertEqual(
            paths.runtime_descriptor.name,
            "dad_infected_vocal_blendshape.json",
        )

    def test_grandma_source_locks_explicit_lattice_mapping(self):
        source = load_source_descriptor(
            self.paths.source_descriptor,
            GRANDMA_PROFILE,
        )
        self.assertEqual(source["donorBlendShapeName"], "Lattice")
        self.assertEqual(source["blendShapeName"], "grandmaVocalClose")

        without_mapping = dict(source)
        without_mapping.pop("donorBlendShapeName")
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "source.json"
            path.write_text(json.dumps(without_mapping), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "donor blendshape name"):
                load_source_descriptor(path, GRANDMA_PROFILE)

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

        fake_usd_skel = types.SimpleNamespace(BindingAPI=lambda _: Binding())
        fake_pxr = types.ModuleType("pxr")
        fake_pxr.UsdSkel = fake_usd_skel
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
            "grandma.infected.vocalBlendShape.v1",
        )
        self.assertEqual(descriptor["characterID"], "grandma")
        self.assertEqual(descriptor["sourceAssetResourceName"], "grandma_biped")
        self.assertEqual(descriptor["blendShapeName"], "grandmaVocalClose")
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
            "grandma_infected_vocal_blendshape_offsets.bin",
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
            "<IIII",
            data,
            16,
        )
        path_start = 32
        path_end = path_start + path_length
        self.assertEqual(
            data[path_start:path_end].decode("utf-8"),
            "/root/Armature/char1/char1",
        )
        self.assertEqual(point_count, 82_854)
        self.assertEqual(record_count, 690)
        self.assertEqual(reserved, 0)
        self.assertEqual(len(data), 19_378)
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
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            "0df8b0f379ca071576dfaa7de3d044e9a0218fe5624242bfb10e424e0813d33b",
        )
        self.assertEqual(descriptor["offsetPayloadMeshCount"], mesh_count)
        self.assertEqual(descriptor["offsetPayloadRecordCount"], record_count)
        self.assertEqual(
            descriptor["offsetPayloadSHA256"],
            hashlib.sha256(data).hexdigest(),
        )

        with zipfile.ZipFile(self.paths.base_asset) as archive:
            names = archive.namelist()
        self.assertFalse(any("mouth_closed" in name for name in names))
        self.assertIn("textures/grandma_biped_ior.png", names)

    def test_report_proves_lattice_resolution_and_output_target(self):
        report = json.loads(
            self.paths.validation_report.read_text(encoding="utf-8")
        )
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(report["characterID"], "grandma")
        self.assertFalse(report["donorBundled"])
        self.assertEqual(
            report["baseAssetSHA256Before"],
            "4a22b7940ad8465dc9fc98acd22c3f5c77edabe2f4342f56790875ae695df5cb",
        )
        self.assertEqual(
            report["donorAssetSHA256"],
            "b9568c4b893d78cf2c0906962066cd2c727f2fbe6d6f8ab74e0f523464a1c3b2",
        )
        mesh = report["validation"]["meshes"][0]
        self.assertEqual(
            mesh["baseTopologySHA256"],
            "a1e4b5f72dcc3c264862a17b6ab3b73e3360d59225bab9d20496be08af3a8563",
        )
        self.assertEqual(mesh["donorTargetSource"], "boundBlendShape")
        self.assertEqual(
            mesh["donorBlendShapePrimPath"],
            "/root/Armature/char1/char1/Lattice",
        )
        self.assertEqual(mesh["donorBlendShapeOffsetRecordCount"], 82_854)
        self.assertEqual(mesh["donorBlendShapeNonzeroOffsetRecordCount"], 614)
        self.assertEqual(mesh["changedPointCount"], 690)
        authored = report["authoredAsset"]["authored"][0]
        self.assertEqual(authored["blendShapeName"], "grandmaVocalClose")
        self.assertEqual(
            authored["blendShapePrimPath"],
            "/root/Armature/char1/char1_grandmaVocalClose",
        )


if __name__ == "__main__":
    unittest.main()
