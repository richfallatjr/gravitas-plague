import CryptoKit
import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

final class NeighborVocalBlendShapeContractTests: XCTestCase {
    private static let expectedAssetSHA256 =
        "f38dba681edb1e4af2452d0f90c8801cd4bc03ad4b84e6e4f69220d3ac2b9636"
    private static let expectedDescriptorSHA256 =
        "f6ba722a0194efa92ac4619aac99d56f2bcf3578c471a0d098ff85d37ab90076"
    private static let expectedPayloadSHA256 =
        "a73e00131328fe3f9a49ba64bdb01bfd6983ec566df96272e973acb300af4758"

    func testNeighborProfileLocksIdentityAndResolution() {
        let neighbor = CharacterVocalBlendShapeProfile.neighbor
        XCTAssertEqual(neighbor.characterID, "neighbor")
        XCTAssertEqual(neighbor.archetype, .neighbor)
        XCTAssertEqual(
            neighbor.descriptorID,
            "neighbor.infected.vocalBlendShape.v1"
        )
        XCTAssertEqual(
            neighbor.descriptorResourceName,
            "neighbor_infected_vocal_blendshape"
        )
        XCTAssertEqual(neighbor.sourceAssetResourceName, "neighbor_biped")
        XCTAssertEqual(neighbor.blendShapeName, "neighborVocalClose")
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(characterID: "neighbor"),
            neighbor
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.resolve(archetype: .neighbor),
            neighbor
        )
        XCTAssertEqual(
            CharacterVocalBlendShapeProfile.supported,
            [.dad, .grandma, .spouse, .biker, neighbor]
        )
    }

    func testNeighborDescriptorAndSparsePayloadLockAuthoredArtifacts() throws {
        let root = try repositoryRoot()
        let resourceDirectory = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance"
        )
        let descriptorURL = resourceDirectory.appendingPathComponent(
            "neighbor_infected_vocal_blendshape.json"
        )
        let payloadURL = resourceDirectory.appendingPathComponent(
            "neighbor_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(try sha256(descriptorURL), Self.expectedDescriptorSHA256)

        let descriptor = try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.schemaVersion, 1)
        XCTAssertEqual(
            descriptor.descriptorID,
            "neighbor.infected.vocalBlendShape.v1"
        )
        XCTAssertEqual(descriptor.characterID, "neighbor")
        XCTAssertEqual(descriptor.sourceAssetResourceName, "neighbor_biped")
        XCTAssertEqual(descriptor.sourceAssetExtension, "usdz")
        XCTAssertEqual(descriptor.sourceAssetSHA256, Self.expectedAssetSHA256)
        XCTAssertEqual(descriptor.blendShapeName, "neighborVocalClose")
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
                "neighbor_infected_vocal_blendshape_offsets.bin"
        )
        XCTAssertEqual(descriptor.offsetPayloadSHA256, Self.expectedPayloadSHA256)
        XCTAssertEqual(descriptor.offsetPayloadMeshCount, 1)
        XCTAssertEqual(descriptor.offsetPayloadRecordCount, 624)

        XCTAssertEqual(
            try sha256(root.appendingPathComponent("neighbor_biped.usdz")),
            Self.expectedAssetSHA256
        )
        let data = try Data(contentsOf: payloadURL)
        XCTAssertEqual(data.count, 17_530)
        XCTAssertEqual(data.prefix(8), Data("GRDADV1\0".utf8))
        XCTAssertEqual(try sha256(payloadURL), Self.expectedPayloadSHA256)

        let payload = try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: 1,
            expectedRecordCount: 624
        )
        XCTAssertEqual(payload.meshes.count, 1)
        let mesh = try XCTUnwrap(payload.meshes.first)
        XCTAssertEqual(mesh.sourcePrimPath, "/root/Armature/char1/char1")
        XCTAssertEqual(mesh.sourcePointCount, 81_816)
        XCTAssertEqual(mesh.records.count, 624)
        XCTAssertEqual(
            mesh.records.map(\.pointIndex),
            mesh.records.map(\.pointIndex).sorted()
        )
        XCTAssertEqual(Set(mesh.records.map(\.pointIndex)).count, 624)
        XCTAssertTrue(mesh.records.allSatisfy { record in
            record.pointIndex >= 0 &&
                record.pointIndex < mesh.sourcePointCount &&
                record.offset.x.isFinite &&
                record.offset.y.isFinite &&
                record.offset.z.isFinite &&
                simd_length_squared(record.offset) > 0
        })
    }

    func testNeighborInventoryLocksExactManifestBackedAudio() throws {
        let expected: [CharacterVocalAudioInventory.Entry] = [
            .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
            .init(role: .damageHit, fileName: "neighbor-damaged-01.wav", sha256: "5c67c59fb6dd1ae05b96709d2cd0daa19643b2a06694a169cd89b326f3146123"),
            .init(role: .damageHit, fileName: "neighbor-damaged-02.wav", sha256: "ac099f4cfe1e0c983a5ce74c93f581bd0082b4eef490d087839824158951aeba"),
            .init(role: .damageHit, fileName: "neighbor-damaged-03.wav", sha256: "fbfc40ae796dffc22b1d54075bf2598a290cc46ed4e35951a08c55fbac821c24"),
            .init(role: .damageHit, fileName: "neighbor-damaged-04.wav", sha256: "4e59bd71ed5a2fa157e7b39637d6db0393e5c5484ab05790243e5426aadd40ba"),
            .init(role: .death, fileName: "neighbor-death-01.wav", sha256: "b3eade454d325b15ebadd815934b1a596a53498ab283ed0b57862f6e331d55fc"),
            .init(role: .death, fileName: "neighbor-death-02.wav", sha256: "53d79558e5a850eb993e77323d6ff7eb0d21afc656ba9a8b1837cd01779d4b82"),
            .init(role: .death, fileName: "neighbor-death-03.wav", sha256: "655853705fe89f83a5e6bae6a16ef2b94293f7f2b26b5f13fc4cb3659ef686b2"),
            .init(role: .death, fileName: "neighbor-death-04.wav", sha256: "e463fb5772a85adb14c29a4c9941efff0be6f017ac105cc7bccf99db3357eea2")
        ]
        XCTAssertEqual(NeighborVocalAudioInventory.ordered, expected)
        XCTAssertEqual(
            CharacterVocalAudioInventory.ordered(characterID: "neighbor"),
            expected
        )
        XCTAssertEqual(expected.filter { $0.role == .presenceLoop }.count, 1)
        XCTAssertEqual(expected.filter { $0.role == .damageHit }.count, 4)
        XCTAssertEqual(expected.filter { $0.role == .death }.count, 4)

        let manifest = try characterManifestAudio(characterID: "neighbor")
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
                "Authored Neighbor audio changed: \(entry.fileName)"
            )
        }
    }

    func testNeighborHordeAndChapter03BigMikeRoutesShareTheVisual() throws {
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
        let mike = try functionBody(named: "prepareMike", in: factory)
        XCTAssertTrue(mike.contains("attributes(for: .neighbor)"))
        XCTAssertTrue(mike.contains("archetype: .neighbor"))

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
            "let chapter03MikeBattle = Chapter03MikeBattleCoordinator(",
            in: immersive
        )
        let registrationEnd = try stringIndex(
            "let chapter03 = Chapter03Coordinator(",
            in: immersive
        )
        let registration = String(immersive[registrationStart..<registrationEnd])
        XCTAssertTrue(
            registration.contains("enemyID, controller, portalMirrorRoot in")
        )
        XCTAssertTrue(registration.contains("archetype: .neighbor"))
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
