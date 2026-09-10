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
        cls.grandma_descriptor_path = (
            cls.performance / "grandma_infected_vocal_blendshape.json"
        )
        cls.grandma_payload_path = (
            cls.performance / "grandma_infected_vocal_blendshape_offsets.bin"
        )
        cls.grandma_asset_path = cls.root / "grandma_biped.usdz"
        cls.spouse_descriptor_path = (
            cls.performance / "spouse_infected_vocal_blendshape.json"
        )
        cls.spouse_payload_path = (
            cls.performance / "spouse_infected_vocal_blendshape_offsets.bin"
        )
        cls.spouse_asset_path = cls.root / "spouse_biped.usdz"
        cls.grandma_manifest_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/Characters/"
            "grandma.character.json"
        )
        cls.spouse_manifest_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/Characters/"
            "spouse.character.json"
        )
        cls.audio_inventory_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
            "VocalBlendShape/CharacterVocalPoseTrackStore.swift"
        )
        cls.vocal_runtime_directory = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
            "VocalBlendShape"
        )
        cls.character_performance_directory = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance"
        )
        cls.viseme_catalog_path = (
            cls.performance / "dad_vocal_viseme_catalog.json"
        )
        cls.dad_viseme_directory = cls.performance / "DadVisemes"
        cls.viseme_track_path = (
            cls.vocal_runtime_directory / "CharacterVocalVisemeTrack.swift"
        )
        cls.viseme_store_path = (
            cls.vocal_runtime_directory / "CharacterVocalVisemeTrackStore.swift"
        )
        cls.compatibility_store_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
            "Compatibility/CharacterVocalCompatibilityPoseTrackStore.swift"
        )
        cls.descriptor_source_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
            "VocalBlendShape/CharacterVocalBlendShapeDescriptor.swift"
        )
        cls.runtime_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
            "VocalBlendShape/DadVocalBlendShapeRuntime.swift"
        )
        cls.audio_controller_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/GravitasDemoAudioController.swift"
        )
        cls.geometry_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
            "VocalBlendShape/CharacterVocalBlendShapeGeometry.swift"
        )
        cls.immersive_coordinator_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        cls.dad_window_coordinator_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/"
            "Chapter01DadWindowCoordinator.swift"
        )
        cls.spouse_window_coordinator_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/"
            "Chapter02WindowWomanCoordinator.swift"
        )
        cls.spouse_battle_coordinator_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/"
            "Chapter02WomanBattleCoordinator.swift"
        )
        cls.battle01_factory_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/Battle/Battle01/"
            "Battle01EnemyFactory.swift"
        )
        cls.battle01_coordinator_path = cls.root / (
            "Gravitas Plague/Gravitas Plague/Battle/Battle01/"
            "Battle01Coordinator.swift"
        )

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

    def test_gpu_stack_recalculates_bounds_after_skinning(self):
        geometry = self.geometry_path.read_text(encoding="utf-8")
        custom = geometry.index("CharacterVocalDenseOffsetDeformer(")
        blend = geometry.index("BlendShapeDeformer()", custom)
        skin = geometry.index("SkinningDeformer(skinsTangentFrame: true)", blend)
        bounds = geometry.index("BoundingBoxCalculator()", skin)
        self.assertLess(custom, blend)
        self.assertLess(blend, skin)
        self.assertLess(skin, bounds)

    def test_grandma_profile_locks_shared_runtime_identity(self):
        source = self.descriptor_source_path.read_text(encoding="utf-8")
        grandma_start = source.index("static let grandma = Self(")
        grandma_end = source.index("static let supported:", grandma_start)
        grandma = source[grandma_start:grandma_end]
        self.assertIn('characterID: "grandma"', grandma)
        self.assertIn("archetype: .grandma", grandma)
        self.assertIn(
            'descriptorID: "grandma.infected.vocalBlendShape.v1"',
            grandma,
        )
        self.assertIn(
            'descriptorResourceName: "grandma_infected_vocal_blendshape"',
            grandma,
        )
        self.assertIn('sourceAssetResourceName: "grandma_biped"', grandma)
        self.assertIn('blendShapeName: "grandmaVocalClose"', grandma)
        self.assertIn(
            "static let supported: [Self] = [.dad, .grandma, .spouse, .biker, .neighbor]",
            source,
        )

        dad_start = source.index("static let dad = Self(")
        dad_end = source.index("static let grandma = Self(", dad_start)
        dad = source[dad_start:dad_end]
        self.assertIn('characterID: "dad"', dad)
        self.assertIn('descriptorID: "dad.infected.vocalBlendShape.v1"', dad)
        self.assertIn('blendShapeName: "dadVocalClose"', dad)

    def test_grandma_generated_descriptor_and_payload_contract_when_present(self):
        descriptor_exists = self.grandma_descriptor_path.exists()
        payload_exists = self.grandma_payload_path.exists()
        if not descriptor_exists and not payload_exists:
            self.skipTest("Grandma runtime artifacts have not been generated yet")
        self.assertTrue(
            descriptor_exists,
            "Grandma descriptor and payload must land together",
        )
        self.assertTrue(
            payload_exists,
            "Grandma descriptor and payload must land together",
        )

        descriptor = json.loads(
            self.grandma_descriptor_path.read_text(encoding="utf-8")
        )
        self.assertEqual(descriptor["schemaVersion"], 1)
        self.assertEqual(
            descriptor["descriptorID"],
            "grandma.infected.vocalBlendShape.v1",
        )
        self.assertEqual(descriptor["characterID"], "grandma")
        self.assertEqual(descriptor["sourceAssetResourceName"], "grandma_biped")
        self.assertEqual(descriptor["sourceAssetExtension"], "usdz")
        self.assertEqual(
            descriptor["sourceAssetSHA256"],
            "c5847e8fe9e4df8e433a31c4492a72f0ea4fcc68d6f910efc68d08fb32bde002",
        )
        self.assertEqual(descriptor["blendShapeName"], "grandmaVocalClose")
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
            descriptor["offsetPayloadResourcePath"],
            "CharacterLibrary/FacialPerformance/"
            "grandma_infected_vocal_blendshape_offsets.bin",
        )
        self.assertEqual(descriptor["offsetPayloadMeshCount"], 1)
        self.assertEqual(descriptor["offsetPayloadRecordCount"], 690)
        self.assertEqual(
            hashlib.sha256(self.grandma_asset_path.read_bytes()).hexdigest(),
            descriptor["sourceAssetSHA256"],
        )

        data = self.grandma_payload_path.read_bytes()
        self.assertEqual(len(data), 19378)
        self.assertEqual(data[:8], b"GRDADV1\0")
        schema, mesh_count = struct.unpack_from("<II", data, 8)
        self.assertEqual(schema, 1)
        self.assertEqual(mesh_count, descriptor["offsetPayloadMeshCount"])
        path_length, point_count, record_count, reserved = struct.unpack_from(
            "<IIII",
            data,
            16,
        )
        path_start = 32
        source_prim_path = data[
            path_start:path_start + path_length
        ].decode("utf-8")
        self.assertEqual(source_prim_path, "/root/Armature/char1/char1")
        self.assertEqual(point_count, 82854)
        self.assertEqual(record_count, 690)
        self.assertEqual(record_count, descriptor["offsetPayloadRecordCount"])
        self.assertEqual(reserved, 0)
        payload_digest = hashlib.sha256(data).hexdigest()
        self.assertEqual(
            payload_digest,
            "0df8b0f379ca071576dfaa7de3d044e9a0218fe5624242bfb10e424e0813d33b",
        )
        self.assertEqual(payload_digest, descriptor["offsetPayloadSHA256"])

    def test_grandma_inventory_locks_exact_nine_manifest_backed_files(self):
        inventory = self.audio_inventory_path.read_text(encoding="utf-8")
        grandma_inventory = self._swift_inventory(inventory, "grandma")
        expected_audio = {
            "dad_breathing.wav": (
                "presenceLoop",
                "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb",
            ),
            "grandma-damaged-01.wav": (
                "damageHit",
                "987f3502330da589d675293815b48bc1e692d03a2cd37b4d57cbdbae27170453",
            ),
            "grandma-damaged-02.wav": (
                "damageHit",
                "6ab48c44af6a4e8b6c1d9c034ac804494a675013566c027d5bf99091e0c8bfc8",
            ),
            "grandma-damaged-03.wav": (
                "damageHit",
                "fab41d36ab369770e9edffa1d06ebc6f04c565da8a893211a7f4e07c9e89fd4d",
            ),
            "grandma-damaged-04.wav": (
                "damageHit",
                "652b9c471876f5a0a7050ad84b44d167990249076d4492c04e646d574950681c",
            ),
            "grandma-death-01.wav": (
                "death",
                "51f0cd4f03d9271c175262a4f62d66378c3ee8636a59aabf613c91e04e13b1dc",
            ),
            "grandma-death-02.wav": (
                "death",
                "38293ffbf3b84bd7a0718d967093f57ab753281a2b9898622549cae7782f5697",
            ),
            "grandma-death-03.wav": (
                "death",
                "a779ff2a8c5fba11915dc875981ff3db04161943c7945093dcac06dada543c79",
            ),
            "grandma-death-04.wav": (
                "death",
                "afdb68decbef7e36c8978b48fe4bc6f3d05f718414966573a0790c5ef5050f8f",
            ),
        }
        for file_name, (role, digest) in expected_audio.items():
            self.assertIn(
                f'.init(role: .{role}, fileName: "{file_name}", sha256: "{digest}")',
                grandma_inventory,
            )
        self.assertEqual(grandma_inventory.count(".init(role:"), 9)
        self.assertEqual(grandma_inventory.count("role: .presenceLoop"), 1)
        self.assertEqual(grandma_inventory.count("role: .damageHit"), 4)
        self.assertEqual(grandma_inventory.count("role: .death"), 4)
        self.assertNotIn("dad-damaged", grandma_inventory)
        self.assertNotIn("dad-death", grandma_inventory)

        manifest = json.loads(
            self.grandma_manifest_path.read_text(encoding="utf-8")
        )["audio"]
        manifest_files = [manifest["presence_loop"]["file"]]
        manifest_files.extend(item["file"] for item in manifest["damage_hits"])
        manifest_files.extend(item["file"] for item in manifest["death"])
        self.assertEqual(list(expected_audio), manifest_files)
        self.assertTrue(manifest["presence_loop"]["spatial"])
        self.assertTrue(manifest["presence_loop"]["loop"])
        self.assertEqual(manifest["presence_loop"]["volume_db"], -7.5)
        self.assertTrue(all(
            item["weight"] == 1.0 and item["volume_db"] == -3.0
            for item in manifest["damage_hits"]
        ))
        self.assertTrue(all(
            item["weight"] == 1.0 and item["volume_db"] == -2.0
            for item in manifest["death"]
        ))
        self.assertEqual(manifest["attack"], [])

        for file_name, (_, expected_digest) in expected_audio.items():
            path = self.root / file_name
            if file_name != "dad_breathing.wav":
                path = self.root / (
                    "Gravitas Plague/Gravitas Plague/Audio/" + file_name
                )
            self.assertTrue(path.exists(), f"missing Grandma audio: {file_name}")
            self.assertEqual(
                hashlib.sha256(path.read_bytes()).hexdigest(),
                expected_digest,
            )

    def test_spouse_profile_descriptor_and_sparse_payload_are_exact(self):
        source = self.descriptor_source_path.read_text(encoding="utf-8")
        spouse_start = source.index("static let spouse = Self(")
        spouse_end = source.index("static let supported:", spouse_start)
        spouse = source[spouse_start:spouse_end]
        self.assertIn('characterID: "spouse"', spouse)
        self.assertIn("archetype: .spouse", spouse)
        self.assertIn(
            'descriptorID: "spouse.infected.vocalBlendShape.v1"',
            spouse,
        )
        self.assertIn(
            'descriptorResourceName: "spouse_infected_vocal_blendshape"',
            spouse,
        )
        self.assertIn('sourceAssetResourceName: "spouse_biped"', spouse)
        self.assertIn('blendShapeName: "spouseVocalClose"', spouse)
        self.assertIn(
            "static let supported: [Self] = [.dad, .grandma, .spouse, .biker, .neighbor]",
            source,
        )

        descriptor_data = self.spouse_descriptor_path.read_bytes()
        self.assertEqual(
            hashlib.sha256(descriptor_data).hexdigest(),
            "2e9cfb47aef2d0ab9bbefc3ab0e9ef02846d4d45147dc1c4ff532428e35ba301",
        )
        descriptor = json.loads(descriptor_data)
        self.assertEqual(descriptor["schemaVersion"], 1)
        self.assertEqual(
            descriptor["descriptorID"],
            "spouse.infected.vocalBlendShape.v1",
        )
        self.assertEqual(descriptor["characterID"], "spouse")
        self.assertEqual(descriptor["sourceAssetResourceName"], "spouse_biped")
        self.assertEqual(descriptor["sourceAssetExtension"], "usdz")
        self.assertEqual(
            descriptor["sourceAssetSHA256"],
            "e3e7d01d4dab7e63b8fce498b3d1b76c28c1f35a98049c6672507ee3fe7e4f67",
        )
        self.assertEqual(descriptor["blendShapeName"], "spouseVocalClose")
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
            descriptor["offsetPayloadResourcePath"],
            "CharacterLibrary/FacialPerformance/"
            "spouse_infected_vocal_blendshape_offsets.bin",
        )
        self.assertEqual(
            hashlib.sha256(self.spouse_asset_path.read_bytes()).hexdigest(),
            descriptor["sourceAssetSHA256"],
        )

        data = self.spouse_payload_path.read_bytes()
        self.assertEqual(len(data), 43_458)
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
        self.assertEqual(point_count, 90_368)
        self.assertEqual(record_count, 1_550)
        self.assertEqual(reserved, 0)
        self.assertEqual(descriptor["offsetPayloadMeshCount"], mesh_count)
        self.assertEqual(descriptor["offsetPayloadRecordCount"], record_count)
        payload_digest = hashlib.sha256(data).hexdigest()
        self.assertEqual(
            payload_digest,
            "376f4b44188f4250e82767f4d57617b280ea2522115209c196f5d193e102977f",
        )
        self.assertEqual(descriptor["offsetPayloadSHA256"], payload_digest)

        with zipfile.ZipFile(self.spouse_asset_path) as archive:
            names = archive.namelist()
        self.assertFalse(any("mouth_closed" in name for name in names))

    def test_spouse_inventory_locks_exact_nine_manifest_backed_files(self):
        inventory = self.audio_inventory_path.read_text(encoding="utf-8")
        spouse_inventory = self._swift_inventory(inventory, "spouse")
        expected_audio = {
            "dad_breathing.wav": (
                "presenceLoop",
                "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb",
            ),
            "spouse-damaged-01.wav": (
                "damageHit",
                "3b10cc19599c05ccad5d48e8b2286a6e46fc95e1593b6ec198d2a3bc3a868ff6",
            ),
            "spouse-damaged-02.wav": (
                "damageHit",
                "17eb441692bbebef553706a99de16ccd6d01825c1b8c5d50097ec1b8453b13d0",
            ),
            "spouse-damaged-03.wav": (
                "damageHit",
                "b1baf3e615a1fbc48beaa70ba605420e896e78e522aff285dc0a47e6c10f9805",
            ),
            "spouse-damaged-04.wav": (
                "damageHit",
                "83d9ccc70b8084bc08231c6b43a73a2a3ed5edab889d172583f50d19eb7f66eb",
            ),
            "spouse-death-01.wav": (
                "death",
                "f785c6c9bcdd71549418a144ae3da9378364cae404a6fe0a25858a244b1a057c",
            ),
            "spouse-death-02.wav": (
                "death",
                "d2a171bf68151b663c2fd7930dfdfd4f1396a1b1e3e7b1fe5d159326237773f4",
            ),
            "spouse-death-03.wav": (
                "death",
                "62de55305b678d9ce38f1a1d82618fefeaccb18b24e8128dcdc2b1d627efa879",
            ),
            "spouse-death-04.wav": (
                "death",
                "1f2f75b7f7f7f2c05c65f558dead60e03525473926d39c29e14c0a9176741a00",
            ),
        }
        for file_name, (role, digest) in expected_audio.items():
            self.assertIn(
                f'.init(role: .{role}, fileName: "{file_name}", sha256: "{digest}")',
                spouse_inventory,
            )
        self.assertEqual(spouse_inventory.count(".init(role:"), 9)
        self.assertEqual(spouse_inventory.count("role: .presenceLoop"), 1)
        self.assertEqual(spouse_inventory.count("role: .damageHit"), 4)
        self.assertEqual(spouse_inventory.count("role: .death"), 4)
        self.assertNotIn("dad-damaged", spouse_inventory)
        self.assertNotIn("grandma-damaged", spouse_inventory)

        manifest = json.loads(
            self.spouse_manifest_path.read_text(encoding="utf-8")
        )["audio"]
        manifest_files = [manifest["presence_loop"]["file"]]
        manifest_files.extend(item["file"] for item in manifest["damage_hits"])
        manifest_files.extend(item["file"] for item in manifest["death"])
        self.assertEqual(list(expected_audio), manifest_files)
        self.assertTrue(manifest["presence_loop"]["spatial"])
        self.assertTrue(manifest["presence_loop"]["loop"])
        self.assertEqual(manifest["presence_loop"]["volume_db"], -7.5)
        self.assertEqual(manifest["attack"], [])

        for file_name, (_, expected_digest) in expected_audio.items():
            path = self.root / file_name
            if file_name != "dad_breathing.wav":
                path = self.root / (
                    "Gravitas Plague/Gravitas Plague/Audio/" + file_name
                )
            self.assertTrue(path.exists(), f"missing Spouse audio: {file_name}")
            self.assertEqual(
                hashlib.sha256(path.read_bytes()).hexdigest(),
                expected_digest,
            )

    def test_spouse_horde_and_chapter02_window_lifecycle_are_bound(self):
        coordinator = self.immersive_coordinator_path.read_text(encoding="utf-8")
        horde_route = self._swift_function(
            coordinator,
            "registerHordeEnemyForInstancedPortalIngress",
        )
        self.assertIn(
            "CharacterVocalBlendShapeProfile.resolve(archetype: archetype) != nil",
            horde_route,
        )
        self.assertIn("attachHostAudioSource(", horde_route)
        self.assertIn(
            "portalMirrorRootEntity: ingress.portalMirrorRootEntity",
            horde_route,
        )
        self.assertIn("breathingStartDelay: 0", horde_route)

        window = self.spouse_window_coordinator_path.read_text(encoding="utf-8")
        prepare = self._swift_function(window, "prepareHidden")
        attach = prepare.index("onWomanRuntimePrepared(sourceID, controller)")
        remember = prepare.index("attachedAudioSourceID = sourceID")
        self.assertLess(remember, attach)

        transfer = self._swift_function(window, "takeStagedRuntime")
        detach = transfer.index(
            'detachAudioSource(reason: "chapter02WomanTransferredToPortalIntro")'
        )
        release_runtime = transfer.index("self.runtime = nil")
        self.assertLess(detach, release_runtime)

        cancel = self._swift_function(window, "cancel")
        detach = cancel.index("detachAudioSource(reason: reason)")
        release_lease = cancel.index("lease.release(reason: .storyReset)")
        self.assertLess(detach, release_lease)

        window_route_start = coordinator.index(
            "let chapter02WindowWoman = Chapter02WindowWomanCoordinator("
        )
        window_route_end = coordinator.index(
            "let chapter02WomanBattle = Chapter02WomanBattleCoordinator(",
            window_route_start,
        )
        window_route = coordinator[window_route_start:window_route_end]
        self.assertIn("onWomanRuntimePrepared:", window_route)
        self.assertIn("attachHostAudioSource(", window_route)
        self.assertIn("archetype: .spouse", window_route)
        self.assertIn("breathingStartDelay: 0", window_route)
        self.assertIn("onWomanRuntimeReleased:", window_route)
        self.assertIn("stopHostAudioSource(id: sourceID)", window_route)

        runtime = self.runtime_path.read_text(encoding="utf-8")
        registration = self._swift_function(runtime, "register")
        self.assertIn(
            "startPrewarmIfNeeded(characterID: profile.characterID)",
            registration,
        )

    def test_chapter02_portal_mirror_is_forwarded_before_source_hide(self):
        battle = self.spouse_battle_coordinator_path.read_text(encoding="utf-8")
        run = self._swift_function(battle, "run")
        mirror = run.index("let mirror = try StoryPortalEnemyRenderMirrorAdapter(")
        callback = run.index("onEnemyPrepared(", mirror)
        hide = run.index("source.rootEntity.isEnabled = false", callback)
        self.assertLess(mirror, callback)
        self.assertLess(callback, hide)
        self.assertIn("mirror.visualRootEntity", run[callback:hide])

        coordinator = self.immersive_coordinator_path.read_text(encoding="utf-8")
        registration_start = coordinator.index(
            "let chapter02WomanBattle = Chapter02WomanBattleCoordinator("
        )
        registration_end = coordinator.index(
            "let chapter02 = Chapter02Coordinator(",
            registration_start,
        )
        registration = coordinator[registration_start:registration_end]
        self.assertIn("enemyID, controller, portalMirrorRoot in", registration)
        self.assertIn("portalMirrorRoot: portalMirrorRoot", registration)

        audio = self._swift_function(
            coordinator,
            "prepareChapter02WomanAudioAndCallbacks",
        )
        self.assertIn("archetype: .spouse", audio)
        self.assertIn("portalMirrorRootEntity: portalMirrorRoot", audio)
        self.assertIn("breathingStartDelay: 0", audio)

    def test_shared_runtime_keeps_character_events_isolated(self):
        runtime = self.runtime_path.read_text(encoding="utf-8")
        receive = self._swift_function(runtime, "receive")
        self.assertIn("guard event.sourceID == sourceID", receive)
        self.assertIn("start.identity.characterID == characterID", receive)
        self.assertIn("start.identity.archetype == archetype", receive)
        self.assertIn("audioRoles.contains", receive)

        request_track = self._swift_function(runtime, "requestTrack")
        self.assertIn(
            "CharacterVocalAudioInventory.asset(for: start)",
            request_track,
        )
        self.assertIn("prewarmTasksByCharacterID", runtime)
        self.assertIn(
            "startPrewarmIfNeeded(characterID: profile.characterID)",
            runtime,
        )

        inventory = self.audio_inventory_path.read_text(encoding="utf-8")
        asset_lookup = self._swift_function(inventory, "asset")
        self.assertIn(
            "characterID: start.identity.characterID",
            asset_lookup,
        )
        self.assertIn("start.identity.archetype == profile.archetype", asset_lookup)
        self.assertIn("characterID: profile.characterID", asset_lookup)
        self.assertIn("fileName: start.identity.fileName", asset_lookup)

    def test_grandma_horde_and_battle01_portal_mirrors_are_bound(self):
        coordinator = self.immersive_coordinator_path.read_text(encoding="utf-8")
        horde_route = self._swift_function(
            coordinator,
            "registerHordeEnemyForInstancedPortalIngress",
        )
        self.assertIn(
            "CharacterVocalBlendShapeProfile.resolve(archetype: archetype) != nil",
            horde_route,
        )
        self.assertNotIn("if archetype == .dad", horde_route)
        self.assertIn("attachHostAudioSource(", horde_route)
        self.assertIn(
            "portalMirrorRootEntity: ingress.portalMirrorRootEntity",
            horde_route,
        )
        self.assertIn("breathingStartDelay: 0", horde_route)

        reveal_route = self._swift_function(
            coordinator,
            "updatePortalIngressControllers",
        )
        self.assertIn(
            "if !audioController.hasActiveCharacterPresenceLoop(id: enemyID)",
            reveal_route,
        )
        self.assertNotIn("controller.archetype != .dad", reveal_route)

        audio_controller = self.audio_controller_path.read_text(encoding="utf-8")
        attach = self._swift_function(audio_controller, "attachHostAudioSource")
        self.assertIn("CharacterVocalBlendShapeProfile.resolve(", attach)
        self.assertIn("archetype: archetype", attach)
        self.assertIn("characterID: vocalProfile.characterID", attach)
        self.assertIn("portalMirrorRoot: portalMirrorRootEntity", attach)

        factory = self.battle01_factory_path.read_text(encoding="utf-8")
        callback_start = factory.index("typealias PreparedCallback")
        callback_end = factory.index(") -> Void", callback_start)
        self.assertIn("Entity?", factory[callback_start:callback_end])
        prepare = self._swift_function(factory, "prepare")
        mirror = prepare.index("let mirror = try StoryPortalEnemyRenderMirrorAdapter(")
        callback = prepare.index(
            "onPrepared(enemyID, source, mirror.visualRootEntity)"
        )
        hide_source = prepare.index("source.rootEntity.isEnabled = false")
        self.assertLess(mirror, callback)
        self.assertLess(callback, hide_source)

        battle_coordinator = self.battle01_coordinator_path.read_text(
            encoding="utf-8"
        )
        hook_start = battle_coordinator.index("typealias EnemyPreparedHook")
        hook_end = battle_coordinator.index(") -> Void", hook_start)
        self.assertIn("Entity?", battle_coordinator[hook_start:hook_end])

        battle_start = coordinator.index("let battle01 = Battle01Coordinator(")
        battle_end = coordinator.index("onEnemyRemoved:", battle_start)
        battle_registration = coordinator[battle_start:battle_end]
        self.assertIn(
            "enemyID, controller, portalMirrorRoot in",
            battle_registration,
        )
        self.assertIn(
            "portalMirrorRoot: portalMirrorRoot",
            battle_registration,
        )
        battle_audio_start = coordinator.index(
            "private func prepareBattle01EnemyAudioAndCallbacks("
        )
        battle_audio_body_start = coordinator.index("{", battle_audio_start)
        battle_audio_signature = coordinator[
            battle_audio_start:battle_audio_body_start
        ]
        self.assertIn("portalMirrorRoot: Entity?", battle_audio_signature)
        battle_audio = self._swift_function(
            coordinator,
            "prepareBattle01EnemyAudioAndCallbacks",
        )
        self.assertIn("archetype: .grandma", battle_audio)
        self.assertIn("portalMirrorRootEntity: portalMirrorRoot", battle_audio)
        self.assertIn("breathingStartDelay: 0", battle_audio)

    def test_dad_shipped_all_phone_manifests_are_exact_and_compact(self):
        catalog = json.loads(
            self.viseme_catalog_path.read_text(encoding="utf-8")
        )
        self.assertEqual(catalog["schemaVersion"], 1)
        self.assertEqual(catalog["catalogID"], "dad.infected.vocalVisemes.v1")
        self.assertEqual(catalog["characterID"], "dad")
        self.assertEqual(
            catalog["compilerVersion"],
            "character-vocal-allphone-visemes/1.0.0",
        )

        ordered = [
            ("presence_loop", "dad_breathing.wav", True),
            ("damage_hits", "dad-damaged-01.wav", False),
            ("damage_hits", "dad-damaged-02.wav", False),
            ("damage_hits", "dad-damaged-03.wav", False),
            ("damage_hits", "dad-damaged-04.wav", False),
            ("death", "dad-death-01.wav", False),
            ("death", "dad-death-02.wav", False),
            ("death", "dad-death-03.wav", False),
            ("death", "dad-death-04.wav", False),
        ]
        entries = catalog["entries"]
        self.assertEqual(
            [
                (entry["role"], entry["audioFile"], entry["looping"])
                for entry in entries
            ],
            ordered,
        )
        self.assertEqual(sum(entry["looping"] for entry in entries), 1)

        descriptor_digest = hashlib.sha256(
            self.descriptor_path.read_bytes()
        ).hexdigest()
        seen_manifests = set()
        required_poses = ["rest", "small", "wide", "round", "teeth"]
        for entry in entries:
            relative_manifest = entry["manifestResourcePath"]
            self.assertTrue(
                relative_manifest.startswith(
                    "CharacterLibrary/FacialPerformance/DadVisemes/"
                )
            )
            manifest_path = (
                self.root / "Gravitas Plague/Gravitas Plague" /
                relative_manifest
            )
            self.assertTrue(manifest_path.is_file())
            self.assertNotIn(manifest_path, seen_manifests)
            seen_manifests.add(manifest_path)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            expected_audio_path = (
                entry["audioFile"]
                if entry["role"] == "presence_loop"
                else f'Audio/{entry["audioFile"]}'
            )
            audio_path = (
                self.root / entry["audioFile"]
                if entry["role"] == "presence_loop"
                else self.root / "Gravitas Plague/Gravitas Plague" /
                expected_audio_path
            )
            self.assertTrue(audio_path.is_file())
            audio_digest = hashlib.sha256(audio_path.read_bytes()).hexdigest()

            self.assertEqual(manifest["schemaVersion"], 1)
            self.assertEqual(
                manifest["compilerVersion"],
                "character-vocal-allphone-visemes/1.0.0",
            )
            self.assertEqual(manifest["characterID"], "dad")
            self.assertEqual(manifest["role"], entry["role"])
            self.assertEqual(manifest["audioFile"], entry["audioFile"])
            self.assertEqual(manifest["audioResourcePath"], expected_audio_path)
            self.assertEqual(manifest["audioSHA256"], entry["audioSHA256"])
            self.assertEqual(audio_digest, entry["audioSHA256"])
            self.assertEqual(manifest["looping"], entry["looping"])
            self.assertEqual(
                manifest["blendShapeDescriptorSHA256"],
                descriptor_digest,
            )
            self.assertEqual(manifest["requiredPoseFamilies"], required_poses)

            alignment = manifest["alignment"]
            self.assertEqual(alignment["mode"], "pocketsphinxAllPhone")
            self.assertEqual(alignment["engine"], "pocketsphinx")
            self.assertEqual(alignment["engineVersion"], "5.1.1")
            self.assertIsNone(alignment["transcriptSHA256"])
            self.assertEqual(
                alignment["speechBoundaryPolicy"],
                "pocketsphinxNonSilencePhoneIntervals",
            )

            timeline = manifest["timeline"]
            self.assertEqual(timeline["sampleRate"], 48_000)
            self.assertEqual(timeline["framesPerSecond"], 60)
            self.assertEqual(timeline["samplesPerNominalFrame"], 800)
            self.assertEqual(
                timeline["frameCount"],
                (timeline["sampleCount"] + 799) // 800,
            )
            self.assertAlmostEqual(
                timeline["durationSeconds"],
                timeline["sampleCount"] / 48_000,
                delta=0.5 / 48_000,
            )

            cursor = 0
            previous_pose = None
            pose_counts = {pose: 0 for pose in required_poses}
            for run in manifest["runs"]:
                self.assertEqual(run["startFrame"], cursor)
                self.assertGreater(run["endFrameExclusive"], cursor)
                self.assertLessEqual(
                    run["endFrameExclusive"], timeline["frameCount"]
                )
                self.assertIn(run["pose"], required_poses)
                self.assertNotEqual(run["pose"], previous_pose)
                pose_counts[run["pose"]] += (
                    run["endFrameExclusive"] - run["startFrame"]
                )
                cursor = run["endFrameExclusive"]
                previous_pose = run["pose"]
            self.assertEqual(cursor, timeline["frameCount"])
            self.assertEqual(
                manifest["summary"]["poseFrameCounts"],
                pose_counts,
            )
            self.assertEqual(
                manifest["summary"]["runCount"], len(manifest["runs"])
            )
            compact_runs = json.dumps(
                manifest["runs"],
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            self.assertEqual(
                hashlib.sha256(compact_runs).hexdigest(),
                manifest["runsSHA256"],
            )

        self.assertEqual(
            {path.name for path in seen_manifests},
            {path.name for path in self.dad_viseme_directory.glob("*.json")},
        )
        self.assertEqual(
            list(self.dad_viseme_directory.glob("*.wav")),
            [],
            "Dad manifests must not copy audio into their resource directory",
        )

    def test_all_character_runtime_uses_authored_tracks_and_exact_audio_clock_authority(self):
        production_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(self.character_performance_directory.rglob("*"))
            if path.suffix in {".swift", ".metal"}
        )
        for forbidden in (
            "TuringGeneratedSpeechAnalyzer",
            "TuringSpeechAmplitudeEnvelope",
            "compatibilityDSP",
            "AVAudioFile",
            "AVAudioConverter",
            "floatChannelData",
            "processedAudio",
            "normalizedEnergy",
            "zeroCrossing",
            "RMS",
            "decibels",
            "amplitude",
            "PCM",
        ):
            self.assertNotIn(forbidden, production_source)

        routing = self.audio_inventory_path.read_text(encoding="utf-8")
        prepare = self._swift_function(routing, "prepare")
        self.assertIn("CharacterVocalBlendShapeProfile.resolve(", prepare)
        self.assertIn("authoredStore.track(for: asset)", prepare)
        self.assertNotIn('asset.characterID == "dad"', prepare)
        self.assertNotIn("compatibilityStore", prepare)
        self.assertFalse(
            self.compatibility_store_path.exists(),
            "The runtime amplitude compatibility store must remain deleted",
        )
        for character_id in ("dad", "grandma", "spouse", "biker", "neighbor"):
            self.assertIn(f'case "{character_id}"', routing)

        authored_store = (
            self.character_performance_directory
            / "VocalBlendShape/CharacterVocalVisemeTrackStore.swift"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "manifest.characterID == configuration.characterID",
            authored_store,
            "A catalog must reject a cross-wired manifest even when shared audio hashes match",
        )

        track = self.viseme_track_path.read_text(encoding="utf-8")
        self.assertIn("let runs: ContiguousArray<Run>", track)
        self.assertIn("cursor: inout Int", track)
        self.assertIn("while cursor + 1 < runs.count", track)
        self.assertIn("binarySearchRun(containing: frame)", track)
        for forbidden in ("AVAudio", "PCM", "samples: [Float]", "Data("):
            self.assertNotIn(forbidden, track)

        runtime = self.runtime_path.read_text(encoding="utf-8")
        receive = self._swift_function(runtime, "receive")
        self.assertIn("private var presenceLoop", runtime)
        self.assertIn("private var oneShot", runtime)
        self.assertIn("private(set) var deathIsTerminal = false", runtime)
        self.assertIn("guard !deathIsTerminal", receive)
        self.assertIn("deathIsTerminal = true", receive)
        self.assertIn("presenceLoop?.start.identity == identity", receive)
        self.assertIn("oneShot?.start.identity == identity", receive)
        self.assertEqual(
            receive.count("presenceLoop?.start.identity == identity"), 2
        )
        self.assertEqual(receive.count("oneShot?.start.identity == identity"), 2)
        self.assertNotIn("deathIsTerminal = false", receive)

        active_pose = self._swift_function(runtime, "activePose")
        self.assertLess(
            active_pose.index("if var oneShot"),
            active_pose.index("if deathIsTerminal"),
        )
        self.assertLess(
            active_pose.index("if deathIsTerminal"),
            active_pose.index("if var presenceLoop"),
        )
        self.assertIn("sample(&oneShot, now: now, loops: false)", active_pose)
        self.assertIn(
            "sample(&presenceLoop, now: now, loops: true)", active_pose
        )

        sample = self._swift_function(runtime, "sample")
        self.assertIn(
            "playback.start.clockOrigin.duration(to: now)", sample
        )
        self.assertIn("rawFrame % track.frameCount", sample)
        self.assertIn(
            "guard rawFrame < track.frameCount else { return .rest }", sample
        )
        self.assertIn(
            "track.pose(atFrame: frame, cursor: &playback.runCursor)", sample
        )
        self.assertNotIn("Date", sample)
        self.assertNotIn("CACurrentMediaTime", sample)

        attach = self._swift_function(runtime, "trackDidBecomeReady")
        self.assertIn("track.identity.matches(identity)", attach)
        self.assertIn("presenceLoop?.start.identity == identity", attach)
        self.assertIn("oneShot?.start.identity == identity", attach)
        self.assertIn("runCursor = 0", attach)

        request_track = self._swift_function(runtime, "requestTrack")
        self.assertIn(
            "CharacterVocalAudioInventory.asset(for: start)", request_track
        )
        self.assertIn("let requestToken: UUID", runtime)
        self.assertIn("let requestToken = UUID()", request_track)
        self.assertIn(
            "trackJoinTasks[playbackID]?.requestToken == requestToken",
            request_track,
        )
        self.assertIn(
            "trackJoinTasks.removeValue(forKey: playbackID)", request_track
        )
        self.assertIn("requestToken: requestToken", request_track)
        self.assertIn("for: start.identity", request_track)
        self.assertNotIn("buffered.count == 16", runtime)
        self.assertNotIn("buffered.removeFirst()", runtime)

        clear = self._swift_function(runtime, "clear")
        self.assertIn("presenceLoop = nil", clear)
        self.assertIn("oneShot = nil", clear)
        self.assertIn("deathIsTerminal = false", clear)
        reset = self._swift_function(runtime, "reset")
        self.assertIn("authority.clear()", reset)
        self.assertIn("descriptor.fallbackWeight", reset)

        audio = self.audio_controller_path.read_text(encoding="utf-8")
        presence_audio = self._swift_function(audio, "startCharacterLoopAudio")
        self.assertIn("fileName: loopFile.fullName", presence_audio)
        self.assertIn("isLooping: true", presence_audio)
        presence_play = presence_audio.index(
            "source.headEntity.playAudio(loopResource)"
        )
        presence_clock = presence_audio.index(
            "let clockOrigin = ContinuousClock.now", presence_play
        )
        presence_publish = presence_audio.index(
            "characterVocalPlaybackEventHub.publish(.started", presence_clock
        )
        self.assertLess(presence_play, presence_clock)
        self.assertLess(presence_clock, presence_publish)

        one_shot_audio = self._swift_function(
            audio, "playReplacingCharacterVocal"
        )
        self.assertIn("fileName: file.fullName", one_shot_audio)
        self.assertIn("isLooping: false", one_shot_audio)
        one_shot_play = one_shot_audio.index(
            "source.headEntity.playAudio(resource)"
        )
        one_shot_clock = one_shot_audio.index(
            "let clockOrigin = ContinuousClock.now", one_shot_play
        )
        one_shot_publish = one_shot_audio.index(
            "characterVocalPlaybackEventHub.publish(.started", one_shot_clock
        )
        self.assertLess(one_shot_play, one_shot_clock)
        self.assertLess(one_shot_clock, one_shot_publish)

        completion = self._swift_function(audio, "completeCharacterVocal")
        self.assertLess(
            completion.index("active.identity == identity"),
            completion.index("publish(.completed(identity))"),
        )

    def test_breathing_inventory_and_shared_registration_contract(self):
        inventory = self.audio_inventory_path.read_text(encoding="utf-8")
        dad_inventory = self._swift_inventory(inventory, "dad")
        runtime = self.runtime_path.read_text(encoding="utf-8")
        coordinator = self.immersive_coordinator_path.read_text(encoding="utf-8")

        expected_audio = {
            "dad_breathing.wav": (
                "presenceLoop",
                "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb",
            ),
            "dad-damaged-01.wav": (
                "damageHit",
                "fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5",
            ),
            "dad-damaged-02.wav": (
                "damageHit",
                "024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71",
            ),
            "dad-damaged-03.wav": (
                "damageHit",
                "e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1",
            ),
            "dad-damaged-04.wav": (
                "damageHit",
                "4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf",
            ),
            "dad-death-01.wav": (
                "death",
                "670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4",
            ),
            "dad-death-02.wav": (
                "death",
                "bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff",
            ),
            "dad-death-03.wav": (
                "death",
                "a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc",
            ),
            "dad-death-04.wav": (
                "death",
                "48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205",
            ),
        }
        for file_name, (role, digest) in expected_audio.items():
            self.assertIn(
                f'.init(role: .{role}, fileName: "{file_name}", sha256: "{digest}")',
                dad_inventory,
            )
        self.assertEqual(dad_inventory.count(".init(role:"), 9)
        self.assertNotIn("grandma-damaged", dad_inventory)
        self.assertNotIn("grandma-death", dad_inventory)
        self.assertIn("case .presenceLoop:\n            isLooping", inventory)
        self.assertIn("case .damageHit, .death:\n            !isLooping", inventory)

        self.assertIn("private var presenceLoop", runtime)
        self.assertIn("if var presenceLoop", runtime)
        self.assertIn(
            "sample(&presenceLoop, now: now, loops: true)",
            runtime,
        )
        self.assertIn("self.presenceLoop = presenceLoop", runtime)
        self.assertIn("if var oneShot", runtime)
        self.assertIn("sample(&oneShot, now: now, loops: false)", runtime)
        self.assertIn(
            "track.pose(atFrame: frame, cursor: &playback.runCursor)", runtime
        )
        self.assertIn("CharacterVocalAudioInventory.assets(", runtime)
        self.assertIn("characterID: characterID", runtime)

        window_start = coordinator.index(
            "let dadWindow = Chapter01DadWindowCoordinator("
        )
        window_end = coordinator.index("let postRobotInteractions", window_start)
        window_route = coordinator[window_start:window_end]
        self.assertIn("onDadRuntimePrepared:", window_route)
        self.assertIn("attachHostAudioSource(", window_route)
        self.assertIn("hostRootEntity: controller.rootEntity", window_route)
        self.assertIn("archetype: .dad", window_route)
        self.assertIn("breathingStartDelay: 0", window_route)
        self.assertIn("onDadRuntimeReleased:", window_route)
        self.assertIn("stopHostAudioSource(id: sourceID)", window_route)

        window_coordinator = self.dad_window_coordinator_path.read_text(
            encoding="utf-8"
        )
        self.assertLess(
            window_coordinator.index(
                'detachDadAudioSource(reason: "dadReachedWindowExit")'
            ),
            window_coordinator.index("runtime.lease.release("),
        )
        self.assertIn(
            "detachDadAudioSource(reason: reason)",
            window_coordinator,
        )

        horde_start = coordinator.index(
            "func registerHordeEnemyForInstancedPortalIngress("
        )
        horde_end = coordinator.index("\n    private func ", horde_start + 1)
        horde_route = coordinator[horde_start:horde_end]
        self.assertIn(
            "CharacterVocalBlendShapeProfile.resolve(archetype: archetype) != nil",
            horde_route,
        )
        self.assertNotIn("if archetype == .dad", horde_route)
        self.assertIn("attachHostAudioSource(", horde_route)
        self.assertIn(
            "portalMirrorRootEntity: ingress.portalMirrorRootEntity",
            horde_route,
        )
        self.assertIn("breathingStartDelay: 0", horde_route)

        reveal_start = coordinator.index("func updatePortalIngressControllers(")
        reveal_end = coordinator.index("\n    private func ", reveal_start + 1)
        reveal_route = coordinator[reveal_start:reveal_end]
        self.assertIn(
            "if !audioController.hasActiveCharacterPresenceLoop(id: enemyID)",
            reveal_route,
        )
        self.assertNotIn("controller.archetype != .dad", reveal_route)
        failed_cleanup = reveal_route[reveal_route.index("for enemyID in failedIDs"):]
        self.assertIn(
            "audioController.stopHostAudioSource(id: enemyID)",
            failed_cleanup,
        )
        self.assertLess(
            failed_cleanup.index("audioController.stopHostAudioSource(id: enemyID)"),
            failed_cleanup.index("portal_ingress_failed"),
        )

    @staticmethod
    def _swift_inventory(source, name):
        marker = f"private static let {name}: [Entry] = ["
        start = source.index(marker)
        end = source.index("\n    ]", start) + len("\n    ]")
        return source[start:end]

    @staticmethod
    def _swift_function(source, name):
        signature = f"func {name}("
        start = source.index(signature)
        opening_brace = source.index("{", start)
        depth = 0
        for index in range(opening_brace, len(source)):
            character = source[index]
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return source[opening_brace:index + 1]
        raise AssertionError(f"unterminated Swift function: {name}")


if __name__ == "__main__":
    unittest.main()
