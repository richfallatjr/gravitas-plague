import CryptoKit
import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

final class BikerVocalBlendShapeContractTests: XCTestCase {
    private static let expectedAssetSHA256 =
        "57bc9c0d8cb44f6039af12f8af61c747cace6ae2293a8bf1fc2cbcbd734d5588"
    private static let expectedDescriptorSHA256 =
        "ff66756413c307b49a4398bf3e1dce34d0357c0fb37fa1dee364722d8f081015"
    private static let expectedPayloadSHA256 =
        "40ac54b9a30ede50581d585106ae7f8b659b805cb63fa1557296937636715548"

    func testBikerProfileLocksIdentityAndResolution() {
        let biker = CharacterVocalBlendShapeProfile.biker
        XCTAssertEqual(biker.characterID, "biker")
        XCTAssertEqual(biker.archetype, .biker)
        XCTAssertEqual(biker.descriptorID, "biker.infected.vocalBlendShape.v1")
        XCTAssertEqual(
            biker.descriptorResourceName,
            "biker_infected_vocal_blendshape"
        )
        XCTAssertEqual(biker.sourceAssetResourceName, "biker_biped")
        XCTAssertEqual(biker.blendShapeName, "bikerVocalClose")
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(characterID: "biker"),
            biker
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(archetype: .biker),
            biker
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.supported,
            [.dad, .grandma, .spouse, biker, .neighbor]
        )
    }

    func testBikerDescriptorAndSparsePayloadLockAuthoredArtifacts() throws {
        let root = try repositoryRoot()
        let resourceDirectory = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance"
        )
        let descriptorURL = resourceDirectory.appendingPathComponent(
            "biker_infected_vocal_blendshape.json"
        )
        let payloadURL = resourceDirectory.appendingPathComponent(
            "biker_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(try sha256(descriptorURL), Self.expectedDescriptorSHA256)

        let descriptor = try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.schemaVersion, 1)
        XCTAssertEqual(descriptor.descriptorID, "biker.infected.vocalBlendShape.v1")
        XCTAssertEqual(descriptor.characterID, "biker")
        XCTAssertEqual(descriptor.sourceAssetResourceName, "biker_biped")
        XCTAssertEqual(descriptor.sourceAssetExtension, "usdz")
        XCTAssertEqual(descriptor.sourceAssetSHA256, Self.expectedAssetSHA256)
        XCTAssertEqual(descriptor.blendShapeName, "bikerVocalClose")
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
                "biker_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(descriptor.offsetPayloadSHA256, Self.expectedPayloadSHA256)
        XCTAssertEqual(descriptor.offsetPayloadMeshCount, 1)
        XCTAssertEqual(descriptor.offsetPayloadRecordCount, 878)

        XCTAssertEqual(
            try sha256(root.appendingPathComponent("biker_biped.usdz")),
            Self.expectedAssetSHA256
        )
        let data = try Data(contentsOf: payloadURL)
        XCTAssertEqual(data.count, 24_642)
        XCTAssertEqual(data.prefix(8), Data("GRDADV1\0".utf8))
        XCTAssertEqual(try sha256(payloadURL), Self.expectedPayloadSHA256)

        let payload = try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: 1,
            expectedRecordCount: 878
        )
        XCTAssertEqual(payload.meshes.count, 1)
        let mesh = try XCTUnwrap(payload.meshes.first)
        XCTAssertEqual(mesh.sourcePrimPath, "/root/Armature/char1/char1")
        XCTAssertEqual(mesh.sourcePointCount, 83_891)
        XCTAssertEqual(mesh.records.count, 878)
        XCTAssertEqual(
            mesh.records.map(\.pointIndex),
            mesh.records.map(\.pointIndex).sorted()
        )
        XCTAssertEqual(Set(mesh.records.map(\.pointIndex)).count, 878)
        XCTAssertTrue(mesh.records.allSatisfy { record in
            record.pointIndex >= 0 &&
                record.pointIndex < mesh.sourcePointCount &&
                record.offset.x.isFinite &&
                record.offset.y.isFinite &&
                record.offset.z.isFinite &&
                simd_length_squared(record.offset) > 0
        })
    }

    func testBikerInventoryLocksExactManifestBackedAudio() throws {
        let expected: [CharacterVocalAudioInventory.Entry] = [
            .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
            .init(role: .damageHit, fileName: "biker-damaged-01.wav", sha256: "817c1ee8343ea12320961fe13e525e5c47c3e224dc2b167927c0f407b22130df"),
            .init(role: .damageHit, fileName: "biker-damaged-02.wav", sha256: "2b5a8ada1d149465a803d0e96af40dd678c7de706b85c6dda371e0cf445f93a0"),
            .init(role: .damageHit, fileName: "biker-damaged-03.wav", sha256: "a68a02a758942e9cfcfb1f3854891008a39caf766614b391b0807c2d13fe7ce2"),
            .init(role: .damageHit, fileName: "biker-damaged-04.wav", sha256: "c25cc41f8a50bdfd8cd07260bfc9efcf0e225295ebc5be660fb9c4a45346b9d7"),
            .init(role: .death, fileName: "biker-death-01.wav", sha256: "2f3345b8073e3f5b86256f33f6f3e81466a5252b22c17d998bb82507b6359c33"),
            .init(role: .death, fileName: "biker-death-02.wav", sha256: "1a04eb28f3b7900ac3ace88640a75fda79bf727b4c82f4976bcdfcf6f6d833b0"),
            .init(role: .death, fileName: "biker-death-03.wav", sha256: "57e1193655477f76daa6d854e4fca6d15b699901e1e96d79c236acaa19262c1c"),
            .init(role: .death, fileName: "biker-death-04.wav", sha256: "a736672b0fd2f4ee1aa55c71002c329c32049b0d957b3897f528e7baa398f880")
        ]
        XCTAssertEqual(BikerVocalAudioInventory.ordered, expected)
        XCTAssertEqual(
            CharacterVocalAudioInventory.ordered(characterID: "biker"),
            expected
        )
        XCTAssertEqual(expected.filter { $0.role == .presenceLoop }.count, 1)
        XCTAssertEqual(expected.filter { $0.role == .damageHit }.count, 4)
        XCTAssertEqual(expected.filter { $0.role == .death }.count, 4)

        let manifest = try characterManifestAudio(characterID: "biker")
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
            let relativePath = entry.role == .presenceLoop
                ? entry.fileName
                : "Gravitas Plague/Gravitas Plague/Audio/\(entry.fileName)"
            XCTAssertEqual(
                try sha256(root.appendingPathComponent(relativePath)),
                entry.sha256,
                "Authored Biker audio changed: \(entry.fileName)"
            )
        }
    }

    func testBikerHordeAndChapter03PortalRoutesShareTheVisual() throws {
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
        XCTAssertTrue(
            ingress.contains("portalMirrorRootEntity: ingress.portalMirrorRootEntity")
        )
        XCTAssertTrue(ingress.contains("breathingStartDelay: 0"))

        let factory = try source(
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/" +
                "Chapter03BattleEnemyFactory.swift"
        )
        let prepare = try functionBody(named: "prepare", in: factory)
        let mirror = try stringIndex(
            "let mirror = try StoryPortalEnemyRenderMirrorAdapter(",
            in: prepare
        )
        let callback = try stringIndex(
            "onPrepared(enemyID, source, mirror.visualRootEntity)",
            in: prepare
        )
        let hide = try stringIndex("source.rootEntity.isEnabled = false", in: prepare)
        XCTAssertLessThan(mirror, callback)
        XCTAssertLessThan(callback, hide)

        let registrationStart = try stringIndex(
            "let chapter03BikerBattle = Chapter03BikerBattleCoordinator(",
            in: immersive
        )
        let registrationEnd = try stringIndex(
            "let chapter03MikeBattle = Chapter03MikeBattleCoordinator(",
            in: immersive
        )
        let registration = String(immersive[registrationStart..<registrationEnd])
        XCTAssertTrue(
            registration.contains("enemyID, controller, portalMirrorRoot in")
        )
        XCTAssertTrue(registration.contains("archetype: .biker"))
        XCTAssertTrue(registration.contains("portalMirrorRoot: portalMirrorRoot"))

        let audio = try functionBody(
            named: "prepareChapter03BattleAudioAndCallbacks",
            in: immersive
        )
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
