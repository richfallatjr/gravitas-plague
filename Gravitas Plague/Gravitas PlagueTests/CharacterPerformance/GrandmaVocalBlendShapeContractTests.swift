import CryptoKit
import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

final class GrandmaVocalBlendShapeContractTests: XCTestCase {
    private static let expectedAssetSHA256 =
        "c5847e8fe9e4df8e433a31c4492a72f0ea4fcc68d6f910efc68d08fb32bde002"
    private static let expectedPayloadSHA256 =
        "0df8b0f379ca071576dfaa7de3d044e9a0218fe5624242bfb10e424e0813d33b"

    func testGrandmaProfileLocksIdentityWithoutChangingDadProfile() {
        let grandma = CharacterVocalBlendShapeProfile.grandma
        XCTAssertEqual(grandma.characterID, "grandma")
        XCTAssertEqual(grandma.archetype, .grandma)
        XCTAssertEqual(
            grandma.descriptorID,
            "grandma.infected.vocalBlendShape.v1"
        )
        XCTAssertEqual(
            grandma.descriptorResourceName,
            "grandma_infected_vocal_blendshape"
        )
        XCTAssertEqual(grandma.sourceAssetResourceName, "grandma_biped")
        XCTAssertEqual(grandma.blendShapeName, "grandmaVocalClose")
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(characterID: "grandma"),
            grandma
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(archetype: .grandma),
            grandma
        )

        let dad = CharacterVocalBlendShapeProfile.dad
        XCTAssertEqual(dad.characterID, "dad")
        XCTAssertEqual(dad.archetype, .dad)
        XCTAssertEqual(dad.descriptorID, "dad.infected.vocalBlendShape.v1")
        XCTAssertEqual(dad.descriptorResourceName, "dad_infected_vocal_blendshape")
        XCTAssertEqual(dad.sourceAssetResourceName, "dad_biped")
        XCTAssertEqual(dad.blendShapeName, "dadVocalClose")
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.supported,
            [dad, grandma, .spouse, .biker, .neighbor]
        )
    }

    func testGrandmaDescriptorAndPayloadLinkLockedArtifactsWhenPresent() throws {
        let root = try repositoryRoot()
        let descriptorURL = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "FacialPerformance/grandma_infected_vocal_blendshape.json"
        )
        let payloadURL = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "FacialPerformance/grandma_infected_vocal_blendshape_offsets.bin"
        )
        let descriptorExists = FileManager.default.fileExists(
            atPath: descriptorURL.path
        )
        let payloadExists = FileManager.default.fileExists(atPath: payloadURL.path)

        guard descriptorExists || payloadExists else {
            throw XCTSkip("Grandma runtime artifacts have not been generated yet")
        }
        XCTAssertTrue(descriptorExists, "Grandma descriptor and payload must land together")
        XCTAssertTrue(payloadExists, "Grandma descriptor and payload must land together")
        guard descriptorExists, payloadExists else { return }

        let descriptor = try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.schemaVersion, 1)
        XCTAssertEqual(descriptor.descriptorID, "grandma.infected.vocalBlendShape.v1")
        XCTAssertEqual(descriptor.characterID, "grandma")
        XCTAssertEqual(descriptor.sourceAssetResourceName, "grandma_biped")
        XCTAssertEqual(descriptor.sourceAssetExtension, "usdz")
        XCTAssertEqual(descriptor.sourceAssetSHA256, Self.expectedAssetSHA256)
        XCTAssertEqual(descriptor.blendShapeName, "grandmaVocalClose")
        XCTAssertEqual(descriptor.basePose, "wide")
        XCTAssertEqual(
            descriptor.poseWeights,
            .init(rest: 1, small: 0.5, wide: 0, round: 0.5, teeth: 1)
        )
        XCTAssertEqual(descriptor.fallbackWeight, 1)
        XCTAssertEqual(descriptor.allowedWeightRange, [0, 1])
        XCTAssertEqual(
            descriptor.audioRoles,
            [.presenceLoop, .damageHit, .death]
        )
        let payloadResourcePath = try XCTUnwrap(
            descriptor.offsetPayloadResourcePath
        )
        let payloadSHA256 = try XCTUnwrap(descriptor.offsetPayloadSHA256)
        let payloadMeshCount = try XCTUnwrap(descriptor.offsetPayloadMeshCount)
        let payloadRecordCount = try XCTUnwrap(
            descriptor.offsetPayloadRecordCount
        )
        XCTAssertEqual(
            payloadResourcePath,
            "CharacterLibrary/FacialPerformance/" +
                "grandma_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(payloadSHA256, Self.expectedPayloadSHA256)
        XCTAssertEqual(payloadMeshCount, 1)
        XCTAssertEqual(payloadRecordCount, 690)

        let assetURL = root.appendingPathComponent("grandma_biped.usdz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(try sha256(assetURL), descriptor.sourceAssetSHA256)

        let data = try Data(contentsOf: payloadURL)
        XCTAssertEqual(data.count, 19_378)
        XCTAssertEqual(data.prefix(8), Data("GRDADV1\0".utf8))
        XCTAssertEqual(try sha256(payloadURL), payloadSHA256)

        let payload = try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: payloadMeshCount,
            expectedRecordCount: payloadRecordCount
        )
        XCTAssertEqual(payload.meshes.count, 1)
        let mesh = try XCTUnwrap(payload.meshes.first)
        XCTAssertEqual(mesh.sourcePrimPath, "/root/Armature/char1/char1")
        XCTAssertEqual(mesh.sourcePointCount, 82_854)
        XCTAssertEqual(mesh.records.count, 690)
        XCTAssertEqual(
            mesh.records.map(\.pointIndex),
            mesh.records.map(\.pointIndex).sorted()
        )
        XCTAssertEqual(Set(mesh.records.map(\.pointIndex)).count, mesh.records.count)
        XCTAssertTrue(mesh.records.allSatisfy { record in
            record.pointIndex >= 0 &&
                record.pointIndex < mesh.sourcePointCount &&
                record.basePosition.x.isFinite &&
                record.basePosition.y.isFinite &&
                record.basePosition.z.isFinite &&
                record.offset.x.isFinite &&
                record.offset.y.isFinite &&
                record.offset.z.isFinite &&
                simd_length_squared(record.offset) > 0
        })
    }

    func testGrandmaInventoryLocksExactNineManifestBackedFilesAndHashes() throws {
        let expected: [CharacterVocalAudioInventory.Entry] = [
            .init(
                role: .presenceLoop,
                fileName: "dad_breathing.wav",
                sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
            ),
            .init(
                role: .damageHit,
                fileName: "grandma-damaged-01.wav",
                sha256: "987f3502330da589d675293815b48bc1e692d03a2cd37b4d57cbdbae27170453"
            ),
            .init(
                role: .damageHit,
                fileName: "grandma-damaged-02.wav",
                sha256: "6ab48c44af6a4e8b6c1d9c034ac804494a675013566c027d5bf99091e0c8bfc8"
            ),
            .init(
                role: .damageHit,
                fileName: "grandma-damaged-03.wav",
                sha256: "fab41d36ab369770e9edffa1d06ebc6f04c565da8a893211a7f4e07c9e89fd4d"
            ),
            .init(
                role: .damageHit,
                fileName: "grandma-damaged-04.wav",
                sha256: "652b9c471876f5a0a7050ad84b44d167990249076d4492c04e646d574950681c"
            ),
            .init(
                role: .death,
                fileName: "grandma-death-01.wav",
                sha256: "51f0cd4f03d9271c175262a4f62d66378c3ee8636a59aabf613c91e04e13b1dc"
            ),
            .init(
                role: .death,
                fileName: "grandma-death-02.wav",
                sha256: "38293ffbf3b84bd7a0718d967093f57ab753281a2b9898622549cae7782f5697"
            ),
            .init(
                role: .death,
                fileName: "grandma-death-03.wav",
                sha256: "a779ff2a8c5fba11915dc875981ff3db04161943c7945093dcac06dada543c79"
            ),
            .init(
                role: .death,
                fileName: "grandma-death-04.wav",
                sha256: "afdb68decbef7e36c8978b48fe4bc6f3d05f718414966573a0790c5ef5050f8f"
            )
        ]

        XCTAssertEqual(GrandmaVocalAudioInventory.ordered, expected)
        XCTAssertEqual(
            CharacterVocalAudioInventory.ordered(characterID: "grandma"),
            expected
        )
        XCTAssertEqual(GrandmaVocalAudioInventory.animatedRoles, [
            .presenceLoop,
            .damageHit,
            .death
        ])
        XCTAssertEqual(expected.filter { $0.role == .presenceLoop }.count, 1)
        XCTAssertEqual(expected.filter { $0.role == .damageHit }.count, 4)
        XCTAssertEqual(expected.filter { $0.role == .death }.count, 4)
        XCTAssertEqual(CharacterVocalAudioInventory.ordered(characterID: "unknown"), [])

        let manifest = try characterManifestAudio(characterID: "grandma")
        let presence = try XCTUnwrap(
            (manifest["presence_loop"] as? [String: Any])?["file"] as? String
        )
        let damage = soundFileNames(manifest["damage_hits"])
        let death = soundFileNames(manifest["death"])
        let faceHits = Set(soundFileNames(manifest["face_hits"]))
        let attack = soundFileNames(manifest["attack"])
        XCTAssertEqual(expected.map(\.fileName), [presence] + damage + death)
        XCTAssertTrue(Set(expected.map(\.fileName)).isDisjoint(with: faceHits))
        XCTAssertTrue(attack.isEmpty)

        let root = try repositoryRoot()
        for entry in expected {
            XCTAssertEqual(
                CharacterVocalAudioInventory.entry(
                    characterID: "grandma",
                    role: entry.role,
                    fileName: entry.fileName
                ),
                entry
            )
            let relativePath = entry.role == .presenceLoop
                ? entry.fileName
                : "Gravitas Plague/Gravitas Plague/Audio/\(entry.fileName)"
            let url = root.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Missing authored Grandma audio: \(relativePath)"
            )
            XCTAssertEqual(
                try sha256(url),
                entry.sha256,
                "Authored Grandma audio changed: \(entry.fileName)"
            )
        }

        XCTAssertEqual(DadVocalAudioInventory.ordered.count, 9)
        XCTAssertFalse(
            DadVocalAudioInventory.ordered.contains {
                $0.fileName.hasPrefix("grandma-")
            }
        )
    }

    func testGrandmaEventsCannotCrossCharacterOrArchetypeBoundaries() throws {
        let sourceID = UUID()
        let wrongArchetype = CharacterVocalPlaybackStart(
            identity: .init(
                playbackID: UUID(),
                sourceID: sourceID,
                characterID: "grandma",
                archetype: .dad,
                role: .damageHit,
                fileName: "grandma-damaged-01.wav",
                isLooping: false
            ),
            clockOrigin: .now,
            expectedDurationSeconds: 5
        )
        let wrongCharacter = CharacterVocalPlaybackStart(
            identity: .init(
                playbackID: UUID(),
                sourceID: sourceID,
                characterID: "dad",
                archetype: .grandma,
                role: .damageHit,
                fileName: "grandma-damaged-01.wav",
                isLooping: false
            ),
            clockOrigin: .now,
            expectedDurationSeconds: 5
        )
        XCTAssertNil(CharacterVocalAudioInventory.asset(for: wrongArchetype))
        XCTAssertNil(CharacterVocalAudioInventory.asset(for: wrongCharacter))
        XCTAssertNil(
            CharacterVocalAudioInventory.entry(
                characterID: "dad",
                role: .damageHit,
                fileName: "grandma-damaged-01.wav"
            )
        )

        let runtime = try source(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/DadVocalBlendShapeRuntime.swift"
        )
        let receive = try functionBody(named: "receive", in: runtime)
        XCTAssertTrue(receive.contains("guard event.sourceID == sourceID"))
        XCTAssertTrue(receive.contains("start.identity.characterID == characterID"))
        XCTAssertTrue(receive.contains("start.identity.archetype == profile.archetype"))
        XCTAssertTrue(receive.contains("descriptor.audioRoles.contains"))

        let requestTrack = try functionBody(named: "requestTrack", in: runtime)
        XCTAssertTrue(
            requestTrack.contains("CharacterVocalAudioInventory.asset(for: start)")
        )
        XCTAssertTrue(runtime.contains("prewarmTasksByCharacterID"))
    }

    func testGrandmaHordePortalBindsEarlyAndRoomRevealDoesNotReregister() throws {
        let immersive = try source(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let ingress = try functionBody(
            named: "registerHordeEnemyForInstancedPortalIngress",
            in: immersive
        )
        XCTAssertTrue(
            ingress.contains(
                "CharacterVocalBlendShapeProfile.resolve(archetype: archetype) != nil"
            )
        )
        XCTAssertFalse(ingress.contains("if archetype == .dad"))
        XCTAssertTrue(ingress.contains("attachHostAudioSource("))
        XCTAssertTrue(
            ingress.contains("portalMirrorRootEntity: ingress.portalMirrorRootEntity")
        )
        XCTAssertTrue(ingress.contains("breathingStartDelay: 0"))

        let reveal = try functionBody(
            named: "updatePortalIngressControllers",
            in: immersive
        )
        XCTAssertTrue(
            reveal.contains(
                "if !audioController.hasActiveCharacterPresenceLoop(id: enemyID)"
            )
        )
        XCTAssertFalse(reveal.contains("controller.archetype != .dad"))

        let audioController = try source(
            "Gravitas Plague/Gravitas Plague/GravitasDemoAudioController.swift"
        )
        let attach = try functionBody(named: "attachHostAudioSource", in: audioController)
        XCTAssertTrue(attach.contains("CharacterVocalBlendShapeProfile.resolve("))
        XCTAssertTrue(attach.contains("archetype: archetype"))
        XCTAssertTrue(attach.contains("characterVocalBlendShapeRuntime.register("))
        XCTAssertTrue(attach.contains("characterID: vocalProfile.characterID"))
        XCTAssertTrue(attach.contains("portalMirrorRoot: portalMirrorRootEntity"))
    }

    func testBattle01ForwardsPortalMirrorBeforeGrandmaAudioRegistration() throws {
        let factory = try source(
            "Gravitas Plague/Gravitas Plague/Battle/Battle01/" +
                "Battle01EnemyFactory.swift"
        )
        let callbackStart = try XCTUnwrap(
            factory.range(of: "typealias PreparedCallback")
        )
        let callbackEnd = try XCTUnwrap(
            factory.range(
                of: ") -> Void",
                range: callbackStart.upperBound..<factory.endIndex
            )
        )
        let callbackContract = String(
            factory[callbackStart.lowerBound..<callbackEnd.upperBound]
        )
        XCTAssertTrue(callbackContract.contains("Entity?"))

        let prepare = try functionBody(named: "prepare", in: factory)
        let mirror = try XCTUnwrap(
            prepare.range(of: "let mirror = try StoryPortalEnemyRenderMirrorAdapter(")
        )
        let callback = try XCTUnwrap(
            prepare.range(of: "onPrepared(enemyID, source, mirror.visualRootEntity)")
        )
        let hideSource = try XCTUnwrap(
            prepare.range(of: "source.rootEntity.isEnabled = false")
        )
        XCTAssertLessThan(mirror.lowerBound, callback.lowerBound)
        XCTAssertLessThan(callback.lowerBound, hideSource.lowerBound)

        let coordinator = try source(
            "Gravitas Plague/Gravitas Plague/Battle/Battle01/" +
                "Battle01Coordinator.swift"
        )
        let hookStart = try XCTUnwrap(coordinator.range(of: "typealias EnemyPreparedHook"))
        let hookEnd = try XCTUnwrap(
            coordinator.range(
                of: ") -> Void",
                range: hookStart.upperBound..<coordinator.endIndex
            )
        )
        XCTAssertTrue(
            coordinator[hookStart.lowerBound..<hookEnd.upperBound].contains("Entity?")
        )

        let immersive = try source(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let battleStart = try XCTUnwrap(
            immersive.range(of: "let battle01 = Battle01Coordinator(")
        )
        let battleEnd = try XCTUnwrap(
            immersive.range(
                of: "onEnemyRemoved:",
                range: battleStart.upperBound..<immersive.endIndex
            )
        )
        let battleRegistration = String(
            immersive[battleStart.lowerBound..<battleEnd.lowerBound]
        )
        XCTAssertTrue(
            battleRegistration.contains(
                "enemyID, controller, portalMirrorRoot in"
            )
        )
        XCTAssertTrue(
            battleRegistration.contains("portalMirrorRoot: portalMirrorRoot")
        )

        let audioSignatureStart = try XCTUnwrap(
            immersive.range(of: "private func prepareBattle01EnemyAudioAndCallbacks(")
        )
        let audioBodyStart = try XCTUnwrap(
            immersive[audioSignatureStart.lowerBound...].firstIndex(of: "{")
        )
        let audioSignature = String(
            immersive[audioSignatureStart.lowerBound..<audioBodyStart]
        )
        XCTAssertTrue(audioSignature.contains("portalMirrorRoot: Entity?"))

        let audio = try functionBody(
            named: "prepareBattle01EnemyAudioAndCallbacks",
            in: immersive
        )
        XCTAssertTrue(audio.contains("archetype: .grandma"))
        XCTAssertTrue(audio.contains("portalMirrorRootEntity: portalMirrorRoot"))
        XCTAssertTrue(audio.contains("breathingStartDelay: 0"))
    }

    private func characterManifestAudio(
        characterID: String
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "Characters/\(characterID).character.json"
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(object["audio"] as? [String: Any])
    }

    private func soundFileNames(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: try repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func functionBody(named name: String, in source: String) throws -> String {
        let signature = "func \(name)("
        let signatureRange = try XCTUnwrap(source.range(of: signature))
        let openingBrace = try XCTUnwrap(
            source[signatureRange.lowerBound...].firstIndex(of: "{")
        )
        var cursor = openingBrace
        var depth = 0
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(
            data: try Data(contentsOf: url, options: .mappedIfSafe)
        ).map { String(format: "%02x", $0) }.joined()
    }

    private func repositoryRoot() throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/", cursor.lastPathComponent != "gravitas-plague" {
            cursor.deleteLastPathComponent()
        }
        guard cursor.lastPathComponent == "gravitas-plague" else {
            throw CocoaError(.fileNoSuchFile)
        }
        return cursor
    }
}
