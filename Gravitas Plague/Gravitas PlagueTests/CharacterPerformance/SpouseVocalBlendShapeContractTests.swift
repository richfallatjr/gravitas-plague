import CryptoKit
import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

final class SpouseVocalBlendShapeContractTests: XCTestCase {
    private static let expectedAssetSHA256 =
        "e3e7d01d4dab7e63b8fce498b3d1b76c28c1f35a98049c6672507ee3fe7e4f67"
    private static let expectedDescriptorSHA256 =
        "2e9cfb47aef2d0ab9bbefc3ab0e9ef02846d4d45147dc1c4ff532428e35ba301"
    private static let expectedPayloadSHA256 =
        "376f4b44188f4250e82767f4d57617b280ea2522115209c196f5d193e102977f"

    func testSpouseProfileLocksIdentityAndAllSupportedProfiles() {
        let spouse = CharacterVocalBlendShapeProfile.spouse
        XCTAssertEqual(spouse.characterID, "spouse")
        XCTAssertEqual(spouse.archetype, .spouse)
        XCTAssertEqual(spouse.descriptorID, "spouse.infected.vocalBlendShape.v1")
        XCTAssertEqual(
            spouse.descriptorResourceName,
            "spouse_infected_vocal_blendshape"
        )
        XCTAssertEqual(spouse.sourceAssetResourceName, "spouse_biped")
        XCTAssertEqual(spouse.blendShapeName, "spouseVocalClose")
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(characterID: "spouse"),
            spouse
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(archetype: .spouse),
            spouse
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.supported,
            [.dad, .grandma, spouse, .biker, .neighbor]
        )
    }

    func testSpouseDescriptorAndSparsePayloadLockAuthoredArtifacts() throws {
        let root = try repositoryRoot()
        let descriptorURL = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "FacialPerformance/spouse_infected_vocal_blendshape.json"
        )
        let payloadURL = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "FacialPerformance/spouse_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(try sha256(descriptorURL), Self.expectedDescriptorSHA256)

        let descriptor = try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.schemaVersion, 1)
        XCTAssertEqual(descriptor.descriptorID, "spouse.infected.vocalBlendShape.v1")
        XCTAssertEqual(descriptor.characterID, "spouse")
        XCTAssertEqual(descriptor.sourceAssetResourceName, "spouse_biped")
        XCTAssertEqual(descriptor.sourceAssetExtension, "usdz")
        XCTAssertEqual(descriptor.sourceAssetSHA256, Self.expectedAssetSHA256)
        XCTAssertEqual(descriptor.blendShapeName, "spouseVocalClose")
        XCTAssertEqual(descriptor.basePose, "wide")
        XCTAssertEqual(
            descriptor.poseWeights,
            .init(rest: 1, small: 0.5, wide: 0, round: 0.5, teeth: 1)
        )
        XCTAssertEqual(descriptor.fallbackWeight, 1)
        XCTAssertEqual(descriptor.allowedWeightRange, [0, 1])
        XCTAssertEqual(descriptor.audioRoles, [.presenceLoop, .damageHit, .death])
        XCTAssertEqual(
            descriptor.offsetPayloadResourcePath,
            "CharacterLibrary/FacialPerformance/" +
                "spouse_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(descriptor.offsetPayloadSHA256, Self.expectedPayloadSHA256)
        XCTAssertEqual(descriptor.offsetPayloadMeshCount, 1)
        XCTAssertEqual(descriptor.offsetPayloadRecordCount, 1_550)

        let assetURL = root.appendingPathComponent("spouse_biped.usdz")
        XCTAssertEqual(try sha256(assetURL), Self.expectedAssetSHA256)

        let data = try Data(contentsOf: payloadURL)
        XCTAssertEqual(data.count, 43_458)
        XCTAssertEqual(data.prefix(8), Data("GRDADV1\0".utf8))
        XCTAssertEqual(try sha256(payloadURL), Self.expectedPayloadSHA256)

        let payload = try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: 1,
            expectedRecordCount: 1_550
        )
        XCTAssertEqual(payload.meshes.count, 1)
        let mesh = try XCTUnwrap(payload.meshes.first)
        XCTAssertEqual(mesh.sourcePrimPath, "/root/Armature/char1/char1")
        XCTAssertEqual(mesh.sourcePointCount, 90_368)
        XCTAssertEqual(mesh.records.count, 1_550)
        XCTAssertEqual(
            mesh.records.map(\.pointIndex),
            mesh.records.map(\.pointIndex).sorted()
        )
        XCTAssertEqual(Set(mesh.records.map(\.pointIndex)).count, 1_550)
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

    func testSpouseInventoryLocksExactManifestBackedAudio() throws {
        let expected: [CharacterVocalAudioInventory.Entry] = [
            .init(
                role: .presenceLoop,
                fileName: "dad_breathing.wav",
                sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
            ),
            .init(
                role: .damageHit,
                fileName: "spouse-damaged-01.wav",
                sha256: "3b10cc19599c05ccad5d48e8b2286a6e46fc95e1593b6ec198d2a3bc3a868ff6"
            ),
            .init(
                role: .damageHit,
                fileName: "spouse-damaged-02.wav",
                sha256: "17eb441692bbebef553706a99de16ccd6d01825c1b8c5d50097ec1b8453b13d0"
            ),
            .init(
                role: .damageHit,
                fileName: "spouse-damaged-03.wav",
                sha256: "b1baf3e615a1fbc48beaa70ba605420e896e78e522aff285dc0a47e6c10f9805"
            ),
            .init(
                role: .damageHit,
                fileName: "spouse-damaged-04.wav",
                sha256: "83d9ccc70b8084bc08231c6b43a73a2a3ed5edab889d172583f50d19eb7f66eb"
            ),
            .init(
                role: .death,
                fileName: "spouse-death-01.wav",
                sha256: "f785c6c9bcdd71549418a144ae3da9378364cae404a6fe0a25858a244b1a057c"
            ),
            .init(
                role: .death,
                fileName: "spouse-death-02.wav",
                sha256: "d2a171bf68151b663c2fd7930dfdfd4f1396a1b1e3e7b1fe5d159326237773f4"
            ),
            .init(
                role: .death,
                fileName: "spouse-death-03.wav",
                sha256: "62de55305b678d9ce38f1a1d82618fefeaccb18b24e8128dcdc2b1d627efa879"
            ),
            .init(
                role: .death,
                fileName: "spouse-death-04.wav",
                sha256: "1f2f75b7f7f2c05c65f558dead60e03525473926d39c29e14c0a9176741a00"
            )
        ]
        XCTAssertEqual(SpouseVocalAudioInventory.ordered, expected)
        XCTAssertEqual(
            CharacterVocalAudioInventory.ordered(characterID: "spouse"),
            expected
        )
        XCTAssertEqual(SpouseVocalAudioInventory.animatedRoles, [
            .presenceLoop,
            .damageHit,
            .death
        ])
        XCTAssertEqual(expected.filter { $0.role == .presenceLoop }.count, 1)
        XCTAssertEqual(expected.filter { $0.role == .damageHit }.count, 4)
        XCTAssertEqual(expected.filter { $0.role == .death }.count, 4)

        let manifest = try characterManifestAudio(characterID: "spouse")
        let presence = try XCTUnwrap(
            (manifest["presence_loop"] as? [String: Any])?["file"] as? String
        )
        let damage = soundFileNames(manifest["damage_hits"])
        let death = soundFileNames(manifest["death"])
        let faceHits = Set(soundFileNames(manifest["face_hits"]))
        XCTAssertEqual(expected.map(\.fileName), [presence] + damage + death)
        XCTAssertTrue(Set(expected.map(\.fileName)).isDisjoint(with: faceHits))
        XCTAssertTrue(soundFileNames(manifest["attack"]).isEmpty)

        let root = try repositoryRoot()
        for entry in expected {
            XCTAssertEqual(
                CharacterVocalAudioInventory.entry(
                    characterID: "spouse",
                    role: entry.role,
                    fileName: entry.fileName
                ),
                entry
            )
            let relativePath = entry.role == .presenceLoop
                ? entry.fileName
                : "Gravitas Plague/Gravitas Plague/Audio/\(entry.fileName)"
            let url = root.appendingPathComponent(relativePath)
            XCTAssertEqual(
                try sha256(url),
                entry.sha256,
                "Authored Spouse audio changed: \(entry.fileName)"
            )
        }
    }

    func testSpouseHordePortalRegistersAtIngressWithoutRevealReplacement() throws {
        let immersive = try source(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let ingress = try functionBody(
            named: "registerHordeEnemyForInstancedPortalIngress",
            in: immersive
        )
        XCTAssertNotNil(CharacterVocalBlendShapeProfile.resolve(archetype: .spouse))
        XCTAssertTrue(
            ingress.contains(
                "CharacterVocalBlendShapeProfile.resolve(archetype: archetype) != nil"
            )
        )
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
    }

    func testChapter02WindowRegistrationPrewarmsAndReleasesBeforeTransfer() throws {
        let window = try source(
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/" +
                "Chapter02WindowWomanCoordinator.swift"
        )
        let prepare = try functionBody(named: "prepareHidden", in: window)
        XCTAssertTrue(prepare.contains("attachedAudioSourceID = sourceID"))
        XCTAssertTrue(prepare.contains("onWomanRuntimePrepared(sourceID, controller)"))
        XCTAssertLessThan(
            try stringIndex("attachedAudioSourceID = sourceID", in: prepare),
            try stringIndex("onWomanRuntimePrepared(sourceID, controller)", in: prepare)
        )

        let transfer = try functionBody(named: "takeStagedRuntime", in: window)
        XCTAssertLessThan(
            try stringIndex(
                "detachAudioSource(reason: \"chapter02WomanTransferredToPortalIntro\")",
                in: transfer
            ),
            try stringIndex("self.runtime = nil", in: transfer)
        )
        let cancel = try functionBody(named: "cancel", in: window)
        XCTAssertLessThan(
            try stringIndex("detachAudioSource(reason: reason)", in: cancel),
            try stringIndex("lease.release(reason: .storyReset)", in: cancel)
        )
        let detach = try functionBody(named: "detachAudioSource", in: window)
        XCTAssertTrue(detach.contains("attachedAudioSourceID = nil"))
        XCTAssertTrue(detach.contains("onWomanRuntimeReleased(sourceID, reason)"))

        let immersive = try source(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let routeStart = try stringIndex(
            "let chapter02WindowWoman = Chapter02WindowWomanCoordinator(",
            in: immersive
        )
        let routeEnd = try stringIndex(
            "let chapter02WomanBattle = Chapter02WomanBattleCoordinator(",
            in: immersive
        )
        let route = String(immersive[routeStart..<routeEnd])
        XCTAssertTrue(route.contains("onWomanRuntimePrepared:"))
        XCTAssertTrue(route.contains("attachHostAudioSource("))
        XCTAssertTrue(route.contains("archetype: .spouse"))
        XCTAssertTrue(route.contains("breathingStartDelay: 0"))
        XCTAssertTrue(route.contains("onWomanRuntimeReleased:"))
        XCTAssertTrue(route.contains("stopHostAudioSource(id: sourceID)"))

        let runtime = try source(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/DadVocalBlendShapeRuntime.swift"
        )
        let registration = try functionBody(named: "register", in: runtime)
        XCTAssertTrue(
            registration.contains(
                "startPrewarmIfNeeded(characterID: profile.characterID)"
            )
        )
    }

    func testChapter02PortalMirrorIsForwardedBeforeSourceIsHidden() throws {
        let battle = try source(
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/" +
                "Chapter02WomanBattleCoordinator.swift"
        )
        let run = try functionBody(named: "run", in: battle)
        let mirror = try stringIndex(
            "let mirror = try StoryPortalEnemyRenderMirrorAdapter(",
            in: run
        )
        let callback = try stringIndex(
            "onEnemyPrepared(\n                source.hordeBenchmarkID,\n" +
                "                source,\n                mirror.visualRootEntity\n            )",
            in: run
        )
        let hide = try stringIndex("source.rootEntity.isEnabled = false", in: run)
        XCTAssertLessThan(mirror, callback)
        XCTAssertLessThan(callback, hide)

        let immersive = try source(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let registrationStart = try stringIndex(
            "let chapter02WomanBattle = Chapter02WomanBattleCoordinator(",
            in: immersive
        )
        let registrationEnd = try stringIndex(
            "let chapter02 = Chapter02Coordinator(",
            in: immersive
        )
        let registration = String(immersive[registrationStart..<registrationEnd])
        XCTAssertTrue(
            registration.contains("enemyID, controller, portalMirrorRoot in")
        )
        XCTAssertTrue(
            registration.contains("portalMirrorRoot: portalMirrorRoot")
        )

        let audio = try functionBody(
            named: "prepareChapter02WomanAudioAndCallbacks",
            in: immersive
        )
        XCTAssertTrue(audio.contains("archetype: .spouse"))
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

    private func stringIndex(
        _ needle: String,
        in haystack: String
    ) throws -> String.Index {
        try XCTUnwrap(haystack.range(of: needle)?.lowerBound)
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
