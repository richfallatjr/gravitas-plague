import CryptoKit
import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

final class DadVocalBlendShapeContractTests: XCTestCase {
    func testProductionDescriptorLocksInversePoseMappingAndResponse() throws {
        let descriptor = try productionDescriptor()

        XCTAssertNoThrow(try descriptor.validate())
        XCTAssertEqual(descriptor.descriptorID, "dad.infected.vocalBlendShape.v1")
        XCTAssertEqual(descriptor.characterID, "dad")
        XCTAssertEqual(descriptor.blendShapeName, "dadVocalClose")
        XCTAssertEqual(descriptor.basePose, "wide")
        XCTAssertEqual(descriptor.poseWeights.weight(for: .rest), 1)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .small), 0.5)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .wide), 0)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .round), 0.5)
        XCTAssertEqual(descriptor.poseWeights.weight(for: .teeth), 1)
        XCTAssertEqual(descriptor.fallbackWeight, 1)
        XCTAssertEqual(descriptor.allowedWeightRange, [0, 1])
        XCTAssertEqual(
            descriptor.audioRoles,
            [.damageHit, .death]
        )
        XCTAssertEqual(
            descriptor.response,
            .init(
                increasingWeightHalfLifeSeconds: 0.05,
                decreasingWeightHalfLifeSeconds: 0.03,
                crossingHalfLifeSeconds: 0.035,
                maximumDeltaTimeSeconds: 0.05,
                assignmentEpsilon: 0.0005
            )
        )
    }

    func testDescriptorRejectsMappingOrResponseDrift() throws {
        let invalidMapping = try mutatedProductionDescriptor { object in
            var weights = try XCTUnwrap(
                object["poseWeights"] as? [String: Any]
            )
            weights["wide"] = 1.0
            object["poseWeights"] = weights
        }
        XCTAssertThrowsError(try invalidMapping.validate()) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidDescriptor("lockedPoseMapping")
            )
        }

        let invalidResponse = try mutatedProductionDescriptor { object in
            var response = try XCTUnwrap(
                object["response"] as? [String: Any]
            )
            response["decreasingWeightHalfLifeSeconds"] = 0.05
            object["response"] = response
        }
        XCTAssertThrowsError(try invalidResponse.validate()) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidDescriptor("response")
            )
        }

        let breathingReintroduced = try mutatedProductionDescriptor { object in
            object["audioRoles"] = [
                "presence_loop",
                "damage_hits",
                "death"
            ]
        }
        XCTAssertThrowsError(try breathingReintroduced.validate()) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidDescriptor("audioRoles")
            )
        }
    }

    func testDadInventoryExcludesBreathingAndLocksEightVocalFiles() throws {
        let expected: [DadVocalAudioInventory.Entry] = [
            .init(
                role: .damageHit,
                fileName: "dad-damaged-01.wav",
                sha256: "fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-02.wav",
                sha256: "024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-03.wav",
                sha256: "e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1"
            ),
            .init(
                role: .damageHit,
                fileName: "dad-damaged-04.wav",
                sha256: "4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf"
            ),
            .init(
                role: .death,
                fileName: "dad-death-01.wav",
                sha256: "670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4"
            ),
            .init(
                role: .death,
                fileName: "dad-death-02.wav",
                sha256: "bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff"
            ),
            .init(
                role: .death,
                fileName: "dad-death-03.wav",
                sha256: "a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc"
            ),
            .init(
                role: .death,
                fileName: "dad-death-04.wav",
                sha256: "48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205"
            )
        ]

        XCTAssertEqual(DadVocalAudioInventory.ordered, expected)
        XCTAssertEqual(DadVocalAudioInventory.animatedRoles, [.damageHit, .death])
        XCTAssertEqual(DadVocalAudioInventory.ordered.count, 8)
        XCTAssertEqual(
            DadVocalAudioInventory.ordered.filter { $0.role == .presenceLoop }.count,
            0
        )
        XCTAssertEqual(
            DadVocalAudioInventory.ordered.filter { $0.role == .damageHit }.count,
            4
        )
        XCTAssertEqual(
            DadVocalAudioInventory.ordered.filter { $0.role == .death }.count,
            4
        )
        XCTAssertEqual(
            Set(DadVocalAudioInventory.ordered.map(\.role)),
            Set(DadVocalAudioInventory.animatedRoles)
        )
        XCTAssertFalse(
            DadVocalAudioInventory.drivesAnimation(
                role: .presenceLoop,
                isLooping: true
            )
        )
        XCTAssertFalse(
            DadVocalAudioInventory.drivesAnimation(
                role: .presenceLoop,
                isLooping: false
            )
        )
        XCTAssertTrue(
            DadVocalAudioInventory.drivesAnimation(
                role: .damageHit,
                isLooping: false
            )
        )
        XCTAssertTrue(
            DadVocalAudioInventory.drivesAnimation(
                role: .death,
                isLooping: false
            )
        )
        XCTAssertFalse(
            DadVocalAudioInventory.drivesAnimation(
                role: .damageHit,
                isLooping: true
            )
        )
        XCTAssertTrue(DadVocalAudioInventory.ordered.allSatisfy {
            $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit)
        })

        let manifest = try dadCharacterManifestAudio()
        let presence = try XCTUnwrap(
            (manifest["presence_loop"] as? [String: Any])?["file"] as? String
        )
        let damage = soundFileNames(manifest["damage_hits"])
        let death = soundFileNames(manifest["death"])
        let faceHits = Set(soundFileNames(manifest["face_hits"]))
        let attack = soundFileNames(manifest["attack"])

        XCTAssertEqual(
            DadVocalAudioInventory.ordered.map(\.fileName),
            damage + death
        )
        XCTAssertEqual(presence, "dad_breathing.wav")
        XCTAssertFalse(DadVocalAudioInventory.ordered.map(\.fileName).contains(presence))
        XCTAssertNil(
            DadVocalAudioInventory.entry(
                role: .presenceLoop,
                fileName: presence
            )
        )
        let breathingStart = CharacterVocalPlaybackStart(
            identity: .init(
                playbackID: UUID(),
                sourceID: UUID(),
                characterID: "dad",
                archetype: .dad,
                role: .presenceLoop,
                fileName: presence,
                isLooping: true
            ),
            clockOrigin: .now,
            expectedDurationSeconds: nil
        )
        XCTAssertNil(DadVocalAudioInventory.asset(for: breathingStart))
        XCTAssertTrue(
            Set(DadVocalAudioInventory.ordered.map(\.fileName))
                .isDisjoint(with: faceHits)
        )
        XCTAssertTrue(attack.isEmpty)
    }

    func testAuthoredDadResourcesExistAndMatchLockedHashes() throws {
        let root = try repositoryRoot()
        let descriptor = try productionDescriptor()
        let sourceAssetURL = root.appendingPathComponent("dad_biped.usdz")
        let payloadURL = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/" +
                (try XCTUnwrap(descriptor.offsetPayloadResourcePath))
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAssetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertEqual(try sha256(sourceAssetURL), descriptor.sourceAssetSHA256)
        XCTAssertEqual(
            try sha256(payloadURL),
            try XCTUnwrap(descriptor.offsetPayloadSHA256)
        )

        for entry in DadVocalAudioInventory.ordered {
            let relativePath = "Gravitas Plague/Gravitas Plague/Audio/\(entry.fileName)"
            let url = root.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Missing authored Dad audio: \(relativePath)"
            )
            XCTAssertEqual(
                try sha256(url),
                entry.sha256,
                "Authored Dad audio changed: \(entry.fileName)"
            )
        }

        let breathingURL = root.appendingPathComponent("dad_breathing.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: breathingURL.path))
        XCTAssertEqual(
            try sha256(breathingURL),
            "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
        )

        try assertBundledDadResourcesWhenAvailable(descriptor: descriptor)
    }

    func testOffsetPayloadHasLockedMagicAndCounts() throws {
        let descriptor = try productionDescriptor()
        let data = try productionPayloadData(descriptor: descriptor)

        XCTAssertEqual(data.prefix(8), Data("GRDADV1\0".utf8))

        let payload = try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: try XCTUnwrap(descriptor.offsetPayloadMeshCount),
            expectedRecordCount: try XCTUnwrap(descriptor.offsetPayloadRecordCount)
        )
        XCTAssertEqual(payload.meshes.count, 1)
        let mesh = try XCTUnwrap(payload.meshes.first)
        XCTAssertEqual(mesh.sourcePrimPath, "/root/Armature/char1/char1")
        XCTAssertEqual(mesh.sourcePointCount, 144_525)
        XCTAssertEqual(
            mesh.records.count,
            try XCTUnwrap(descriptor.offsetPayloadRecordCount)
        )
        XCTAssertFalse(mesh.records.isEmpty)
        XCTAssertEqual(
            mesh.records.map(\.pointIndex),
            mesh.records.map(\.pointIndex).sorted()
        )
        XCTAssertTrue(mesh.records.allSatisfy {
            $0.pointIndex >= 0 &&
                $0.pointIndex < mesh.sourcePointCount &&
                simd_length_squared($0.offset) > 0
        })
    }

    func testOffsetPayloadRejectsWrongMagicAndExpectedCounts() throws {
        let descriptor = try productionDescriptor()
        let data = try productionPayloadData(descriptor: descriptor)
        let meshCount = try XCTUnwrap(descriptor.offsetPayloadMeshCount)
        let recordCount = try XCTUnwrap(descriptor.offsetPayloadRecordCount)

        var badMagic = data
        badMagic[badMagic.startIndex] = 0
        XCTAssertThrowsError(try SingleBlendShapeOffsetPayload(
            data: badMagic,
            expectedMeshCount: meshCount,
            expectedRecordCount: recordCount
        )) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidOffsetPayload("magic")
            )
        }

        XCTAssertThrowsError(try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: meshCount + 1,
            expectedRecordCount: recordCount
        )) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidOffsetPayload("meshCount")
            )
        }

        XCTAssertThrowsError(try SingleBlendShapeOffsetPayload(
            data: data,
            expectedMeshCount: meshCount,
            expectedRecordCount: recordCount + 1
        )) { error in
            XCTAssertEqual(
                error as? CharacterVocalBlendShapeError,
                .invalidOffsetPayload("length")
            )
        }
    }

    @MainActor
    func testNativeOffsetValidationUsesOriginalVertexMap() throws {
        let close = SIMD3<Float>(0.1, -0.2, 0.3)
        let source = SingleBlendShapeOffsetPayload.Mesh(
            sourcePrimPath: "/root/Armature/char1/char1",
            sourcePointCount: 3,
            records: [
                .init(
                    pointIndex: 1,
                    basePosition: SIMD3<Float>(1, 2, 3),
                    offset: close
                )
            ]
        )
        let result = try SingleBlendShapeMeshImportValidator.validateNativeOffsets(
            source: source,
            importedPositions: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 2, 3),
                SIMD3<Float>(1, 2, 3),
                SIMD3<Float>(8, 9, 10)
            ],
            originalPartVertexIndices: [0, 1, 1, 2],
            nativeOffsets: [.zero, close, close, .zero],
            registrationTolerance: 0.000_002
        )

        XCTAssertEqual(result.matchedSourceRecordCount, 1)
        XCTAssertEqual(result.matchedRenderVertexCount, 2)
        XCTAssertEqual(result.splitRenderVertexCount, 1)
        XCTAssertEqual(result.maximumNativeOffset, simd_length(close))
    }

    @MainActor
    func testNativeOffsetValidationRejectsWrongMappedDelta() {
        let close = SIMD3<Float>(0, 0.1, 0)
        let source = SingleBlendShapeOffsetPayload.Mesh(
            sourcePrimPath: "/root/Armature/char1/char1",
            sourcePointCount: 2,
            records: [
                .init(
                    pointIndex: 1,
                    basePosition: SIMD3<Float>(1, 0, 0),
                    offset: close
                )
            ]
        )

        XCTAssertThrowsError(try SingleBlendShapeMeshImportValidator.validateNativeOffsets(
            source: source,
            importedPositions: [.zero, SIMD3<Float>(1, 0, 0)],
            originalPartVertexIndices: [0, 1],
            nativeOffsets: [close, .zero],
            registrationTolerance: 0.000_002
        ))
    }

    func testProductionDeformerIsGPUOnDemandAndRunsBeforeSkinning() throws {
        let deformer = CharacterVocalDenseOffsetDeformer(
            stateID: UUID(),
            weight: 0.5,
            vertexCount: 172_668
        )

        XCTAssertEqual(CharacterVocalDenseOffsetDeformer.mode, .gpu)
        XCTAssertEqual(deformer.mode, .gpu)
        XCTAssertEqual(deformer.options.cadence, .onDemand)
        XCTAssertEqual(deformer.options.inputSpec, .positions)
        XCTAssertEqual(deformer.options.outputSpec, .positions)
        XCTAssertEqual(deformer.vertexCount, 172_668)

        let geometryURL = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/CharacterVocalBlendShapeGeometry.swift"
        )
        let geometry = try String(contentsOf: geometryURL, encoding: .utf8)
        XCTAssertFalse(geometry.contains("mesh.replace("))
        XCTAssertFalse(geometry.contains("replace(with:"))

        let custom = try XCTUnwrap(
            geometry.range(of: "CharacterVocalDenseOffsetDeformer(")
        )
        let blend = try XCTUnwrap(
            geometry.range(of: "BlendShapeDeformer()", range: custom.upperBound..<geometry.endIndex)
        )
        let skin = try XCTUnwrap(
            geometry.range(
                of: "SkinningDeformer(skinsTangentFrame: true)",
                range: blend.upperBound..<geometry.endIndex
            )
        )
        XCTAssertLessThan(custom.lowerBound, blend.lowerBound)
        XCTAssertLessThan(blend.lowerBound, skin.lowerBound)

        let metalURL = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/CharacterVocalBlendShapeDeformer.metal"
        )
        let metal = try String(contentsOf: metalURL, encoding: .utf8)
        XCTAssertTrue(metal.contains("kernel void characterVocalApplyDenseOffsets"))
        XCTAssertTrue(metal.contains("position + delta"))
    }

    func testResponseUsesDirectionalAndCrossingHalfLives() throws {
        let response = CharacterVocalBlendShapeResponse(
            try productionDescriptor().response
        )
        let deltaTime: Float = 0.01
        let increasing = response.step(
            current: 0,
            target: 1,
            deltaTime: deltaTime
        )
        let decreasing = response.step(
            current: 1,
            target: 0,
            deltaTime: deltaTime
        )
        XCTAssertEqual(
            increasing,
            1 - exp2(-deltaTime / 0.05),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            decreasing,
            exp2(-deltaTime / 0.03),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(1 - decreasing, increasing)

        let crossingUp = response.step(
            current: 0,
            target: 0.5,
            deltaTime: deltaTime
        )
        let crossingDown = response.step(
            current: 1,
            target: 0.5,
            deltaTime: deltaTime
        )
        let crossingAlpha: Float = 1 - exp2(-deltaTime / 0.035)
        XCTAssertEqual(crossingUp, 0.5 * crossingAlpha, accuracy: 0.000_001)
        XCTAssertEqual(
            crossingDown,
            1 - 0.5 * crossingAlpha,
            accuracy: 0.000_001
        )
    }

    func testResponseCapsDeltaAndConvergesWithoutOvershoot() throws {
        let response = CharacterVocalBlendShapeResponse(
            try productionDescriptor().response
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: 0),
            0.25
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: -1),
            0.25
        )
        XCTAssertEqual(
            response.step(current: 0.25, target: 1, deltaTime: 5),
            response.step(current: 0.25, target: 1, deltaTime: 0.05),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            response.step(current: 0.999_9, target: 1, deltaTime: 1.0 / 60.0),
            1
        )

        try assertConvergence(
            response: response,
            initial: 0,
            target: 1,
            direction: .increasing
        )
        try assertConvergence(
            response: response,
            initial: 1,
            target: 0,
            direction: .decreasing
        )
        try assertConvergence(
            response: response,
            initial: 0,
            target: 0.5,
            direction: .increasing
        )
        try assertConvergence(
            response: response,
            initial: 1,
            target: 0.5,
            direction: .decreasing
        )
        try assertConvergence(
            response: response,
            initial: 0.5,
            target: 0,
            direction: .decreasing
        )
    }

    @MainActor
    func testEventHubPublishesToSubscribersAndCancelIsIsolated() {
        let hub = CharacterVocalPlaybackEventHub()
        let identity = CharacterVocalPlaybackIdentity(
            playbackID: UUID(),
            sourceID: UUID(),
            characterID: "dad",
            archetype: .dad,
            role: .damageHit,
            fileName: "dad-damaged-01.wav",
            isLooping: false
        )
        let start = CharacterVocalPlaybackStart(
            identity: identity,
            clockOrigin: .now,
            expectedDurationSeconds: 0.75
        )
        var firstEvents: [CharacterVocalPlaybackEvent] = []
        var secondEvents: [CharacterVocalPlaybackEvent] = []
        let first = hub.subscribe { firstEvents.append($0) }
        let second = hub.subscribe { secondEvents.append($0) }

        hub.publish(.started(start))
        XCTAssertEqual(firstEvents, [.started(start)])
        XCTAssertEqual(secondEvents, [.started(start)])
        XCTAssertEqual(firstEvents.first?.sourceID, identity.sourceID)

        first.cancel()
        first.cancel()
        hub.publish(.completed(identity))

        XCTAssertEqual(firstEvents, [.started(start)])
        XCTAssertEqual(secondEvents, [.started(start), .completed(identity)])
        withExtendedLifetime(second) {}
    }

    func testFaceHitPathsStayOutOfVocalEventHub() throws {
        let source = try audioControllerSource()
        let faceHitFunctions = [
            "playConfirmedCharacterFaceHitSound",
            "playFacePunchContactSoundIfNeeded",
            "playConcurrentCharacterSpatialOneShot"
        ]

        for name in faceHitFunctions {
            let body = try functionBody(named: name, in: source)
            XCTAssertFalse(
                body.contains("characterVocalPlaybackEventHub.publish"),
                "\(name) must not publish vocal playback events"
            )
            XCTAssertFalse(
                body.contains("CharacterVocalPlaybackIdentity("),
                "\(name) must not manufacture vocal playback identity"
            )
        }
    }

    func testPresenceAndReplacingVocalPathsPublishLifecycleEvents() throws {
        let source = try audioControllerSource()
        let presence = try functionBody(named: "startCharacterLoopAudio", in: source)
        XCTAssertTrue(presence.contains("role: .presenceLoop"))
        XCTAssertTrue(presence.contains("playAudio(loopResource)"))
        XCTAssertTrue(
            presence.contains("characterVocalPlaybackEventHub.publish(.started")
        )

        let replacing = try functionBody(
            named: "playReplacingCharacterVocal",
            in: source
        )
        XCTAssertTrue(replacing.contains("CharacterVocalRole(rawValue: role)"))
        XCTAssertTrue(
            replacing.contains("characterVocalPlaybackEventHub.publish(")
        )
        XCTAssertTrue(replacing.contains(".cancelled(previous.identity"))
        XCTAssertTrue(replacing.contains(".publish(.started"))
    }

    func testDadRuntimeFiltersBreathingAtLiveAndPrewarmAnalysisBoundaries() throws {
        let source = try dadRuntimeSource()
        let controllerReceive = try functionBody(named: "receive", in: source)
        XCTAssertTrue(controllerReceive.contains("drivesAnimation("))
        XCTAssertFalse(source.contains("private var presenceLoop"))

        let requestTrack = try functionBody(named: "requestTrack", in: source)
        XCTAssertTrue(requestTrack.contains("drivesAnimation("))

        let prewarm = try functionBody(named: "startPrewarmIfNeeded", in: source)
        XCTAssertTrue(prewarm.contains("DadVocalAudioInventory.assets()"))
        XCTAssertEqual(DadVocalAudioInventory.ordered.count, 8)
    }

    private enum Direction {
        case increasing
        case decreasing
    }

    private func assertConvergence(
        response: CharacterVocalBlendShapeResponse,
        initial: Float,
        target: Float,
        direction: Direction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var value = initial
        for _ in 0..<240 {
            let next = response.step(
                current: value,
                target: target,
                deltaTime: 1.0 / 60.0
            )
            switch direction {
            case .increasing:
                XCTAssertGreaterThanOrEqual(next, value, file: file, line: line)
                XCTAssertLessThanOrEqual(next, target, file: file, line: line)
            case .decreasing:
                XCTAssertLessThanOrEqual(next, value, file: file, line: line)
                XCTAssertGreaterThanOrEqual(next, target, file: file, line: line)
            }
            XCTAssertTrue(next.isFinite, file: file, line: line)
            value = next
        }
        XCTAssertEqual(
            value,
            target,
            accuracy: response.assignmentEpsilon,
            file: file,
            line: line
        )
    }

    private func productionDescriptor() throws -> CharacterVocalBlendShapeDescriptor {
        try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: productionDescriptorData()
        )
    }

    private func productionDescriptorData() throws -> Data {
        try Data(contentsOf: try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "FacialPerformance/dad_infected_vocal_blendshape.json"
        ))
    }

    private func productionPayloadData(
        descriptor: CharacterVocalBlendShapeDescriptor
    ) throws -> Data {
        let path = try XCTUnwrap(descriptor.offsetPayloadResourcePath)
        return try Data(contentsOf: try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/\(path)"
        ))
    }

    private func mutatedProductionDescriptor(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> CharacterVocalBlendShapeDescriptor {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: productionDescriptorData()
            ) as? [String: Any]
        )
        try mutate(&object)
        return try JSONDecoder().decode(
            CharacterVocalBlendShapeDescriptor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func dadCharacterManifestAudio() throws -> [String: Any] {
        let manifestURL = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterLibrary/" +
                "Characters/dad.character.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)
            ) as? [String: Any]
        )
        return try XCTUnwrap(object["audio"] as? [String: Any])
    }

    private func soundFileNames(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
    }

    private func assertBundledDadResourcesWhenAvailable(
        descriptor: CharacterVocalBlendShapeDescriptor
    ) throws {
        let bundle = Bundle.main
        if let url = bundle.url(
            forResource: "dad_infected_vocal_blendshape",
            withExtension: "json",
            subdirectory: "CharacterLibrary/FacialPerformance"
        ) ?? bundle.url(
            forResource: "dad_infected_vocal_blendshape",
            withExtension: "json"
        ) {
            let bundled = try JSONDecoder().decode(
                CharacterVocalBlendShapeDescriptor.self,
                from: Data(contentsOf: url)
            )
            XCTAssertEqual(bundled, descriptor)
        }

        if let url = bundle.url(forResource: "dad_biped", withExtension: "usdz") {
            XCTAssertEqual(try sha256(url), descriptor.sourceAssetSHA256)
        }

        if let url = bundle.url(
            forResource: "dad_infected_vocal_blendshape_offsets",
            withExtension: "bin",
            subdirectory: "CharacterLibrary/FacialPerformance"
        ) ?? bundle.url(
            forResource: "dad_infected_vocal_blendshape_offsets",
            withExtension: "bin"
        ) {
            XCTAssertEqual(
                try sha256(url),
                try XCTUnwrap(descriptor.offsetPayloadSHA256)
            )
        }

        let bundledAudio = DadVocalAudioInventory.assets(bundle: bundle)
        if !bundledAudio.isEmpty {
            XCTAssertEqual(bundledAudio.count, DadVocalAudioInventory.ordered.count)
            for asset in bundledAudio {
                XCTAssertEqual(try sha256(asset.url), asset.expectedSHA256)
            }
        }

        if let breathingURL = bundle.url(
            forResource: "dad_breathing",
            withExtension: "wav"
        ) {
            XCTAssertEqual(
                try sha256(breathingURL),
                "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"
            )
        }
    }

    private func audioControllerSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/GravitasDemoAudioController.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func dadRuntimeSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/CharacterPerformance/" +
                "VocalBlendShape/DadVocalBlendShapeRuntime.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
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
