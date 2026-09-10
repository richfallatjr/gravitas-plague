import CryptoKit
import Foundation

nonisolated enum CharacterVocalBlendShapeError: Error, Sendable, Equatable {
    case invalidDescriptor(String)
    case missingResource(String)
    case hashMismatch(resource: String, expected: String, actual: String)
    case invalidOffsetPayload(String)
    case meshRepairFailed(String)
    case targetNotFound(String)
    case duplicateTarget(entityPath: String, groupIndex: Int)
    case groupCountMismatch(entityPath: String)
    case weightCountMismatch(entityPath: String, groupIndex: Int)
    case entityReleased(String)
    case staleBinding
    case audioDecodeFailed(String)
    case poseAnalysisFailed(String)
}

nonisolated extension CharacterVocalBlendShapeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDescriptor(let field):
            "Invalid character vocal blendshape descriptor field: \(field)"
        case .missingResource(let resource):
            "Missing character vocal resource: \(resource)"
        case .hashMismatch(let resource, let expected, let actual):
            "Hash mismatch for \(resource); expected \(expected), found \(actual)"
        case .invalidOffsetPayload(let field):
            "Invalid character vocal offset payload: \(field)"
        case .meshRepairFailed(let reason):
            "Character vocal mesh repair failed: \(reason)"
        case .targetNotFound(let target):
            "Character vocal blendshape target not found: \(target)"
        case .duplicateTarget(let path, let group):
            "Duplicate character vocal target at \(path), group \(group)"
        case .groupCountMismatch(let path):
            "Blendshape group count mismatch at \(path)"
        case .weightCountMismatch(let path, let group):
            "Blendshape weight count mismatch at \(path), group \(group)"
        case .entityReleased(let path):
            "Blendshape entity was released: \(path)"
        case .staleBinding:
            "Character vocal blendshape binding is stale"
        case .audioDecodeFailed(let reason):
            "Character vocal PCM decode failed: \(reason)"
        case .poseAnalysisFailed(let reason):
            "Character vocal pose analysis failed: \(reason)"
        }
    }
}

nonisolated struct CharacterVocalPoseWeights: Codable, Sendable, Equatable {
    let rest: Float
    let small: Float
    let wide: Float
    let round: Float
    let teeth: Float

    func weight(for pose: MindEyeMouthPose) -> Float {
        switch pose {
        case .rest: rest
        case .small: small
        case .wide: wide
        case .round: round
        case .teeth: teeth
        }
    }
}

nonisolated struct CharacterVocalBlendShapeResponseDescriptor: Codable, Sendable, Equatable {
    let increasingWeightHalfLifeSeconds: Float
    let decreasingWeightHalfLifeSeconds: Float
    let crossingHalfLifeSeconds: Float
    let maximumDeltaTimeSeconds: Float
    let assignmentEpsilon: Float
}

nonisolated struct CharacterVocalBlendShapeDescriptor: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let descriptorID: String
    let characterID: String
    let sourceAssetResourceName: String
    let sourceAssetExtension: String
    let sourceAssetSHA256: String
    let blendShapeName: String
    let basePose: String
    let poseWeights: CharacterVocalPoseWeights
    let fallbackWeight: Float
    let allowedWeightRange: [Float]
    let audioRoles: [CharacterVocalRole]
    let response: CharacterVocalBlendShapeResponseDescriptor
    let offsetPayloadResourcePath: String?
    let offsetPayloadSHA256: String?
    let offsetPayloadMeshCount: Int?
    let offsetPayloadRecordCount: Int?

    func validate() throws {
        guard schemaVersion == 1 else {
            throw CharacterVocalBlendShapeError.invalidDescriptor("schemaVersion")
        }
        guard descriptorID == "dad.infected.vocalBlendShape.v1",
              characterID == "dad",
              sourceAssetResourceName == "dad_biped",
              sourceAssetExtension == "usdz",
              blendShapeName == "dadVocalClose",
              basePose == "wide" else {
            throw CharacterVocalBlendShapeError.invalidDescriptor("identity")
        }
        guard poseWeights == .init(rest: 1, small: 0.5, wide: 0, round: 0.5, teeth: 1),
              fallbackWeight == 1,
              allowedWeightRange == [0, 1] else {
            throw CharacterVocalBlendShapeError.invalidDescriptor("lockedPoseMapping")
        }
        guard audioRoles == DadVocalAudioInventory.animatedRoles else {
            throw CharacterVocalBlendShapeError.invalidDescriptor("audioRoles")
        }
        let timing = [
            response.increasingWeightHalfLifeSeconds,
            response.decreasingWeightHalfLifeSeconds,
            response.crossingHalfLifeSeconds,
            response.maximumDeltaTimeSeconds,
            response.assignmentEpsilon
        ]
        guard timing.allSatisfy({ $0.isFinite && $0 > 0 }),
              response.increasingWeightHalfLifeSeconds == 0.05,
              response.decreasingWeightHalfLifeSeconds == 0.03,
              response.crossingHalfLifeSeconds == 0.035,
              response.maximumDeltaTimeSeconds == 0.05,
              response.assignmentEpsilon == 0.0005 else {
            throw CharacterVocalBlendShapeError.invalidDescriptor("response")
        }
        let payloadFields: [Any?] = [
            offsetPayloadResourcePath,
            offsetPayloadSHA256,
            offsetPayloadMeshCount,
            offsetPayloadRecordCount
        ]
        let populatedCount = payloadFields.compactMap { $0 }.count
        guard populatedCount == 0 || populatedCount == payloadFields.count else {
            throw CharacterVocalBlendShapeError.invalidDescriptor("offsetPayloadCompleteness")
        }
        if populatedCount > 0 {
            guard offsetPayloadMeshCount ?? 0 > 0,
                  offsetPayloadRecordCount ?? 0 > 0 else {
                throw CharacterVocalBlendShapeError.invalidDescriptor("offsetPayloadCounts")
            }
        }
        for digest in [sourceAssetSHA256, offsetPayloadSHA256].compactMap({ $0 }) {
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }) else {
                throw CharacterVocalBlendShapeError.invalidDescriptor("sha256")
            }
        }
    }
}

nonisolated struct CharacterVocalBlendShapeResources: Sendable {
    let descriptor: CharacterVocalBlendShapeDescriptor
    let offsetPayload: SingleBlendShapeOffsetPayload?
}

actor CharacterVocalBlendShapeDescriptorStore {
    private var cached: Result<CharacterVocalBlendShapeResources, Error>?

    func loadDad(bundle: Bundle = .main) async throws -> CharacterVocalBlendShapeResources {
        if let cached { return try cached.get() }

        let result: Result<CharacterVocalBlendShapeResources, Error>
        do {
            let descriptorURL = try Self.resourceURL(
                bundle: bundle,
                name: "dad_infected_vocal_blendshape",
                extension: "json",
                subdirectory: "CharacterLibrary/FacialPerformance"
            )
            let assetURL = try Self.resourceURL(
                bundle: bundle,
                name: "dad_biped",
                extension: "usdz",
                subdirectory: nil
            )
            let loaded = try await Task.detached(priority: .utility) {
                precondition(!Thread.isMainThread)
                let descriptorData = try Data(contentsOf: descriptorURL)
                let descriptor = try JSONDecoder().decode(
                    CharacterVocalBlendShapeDescriptor.self,
                    from: descriptorData
                )
                try descriptor.validate()

                let assetHash = try Self.sha256(url: assetURL)
                guard assetHash == descriptor.sourceAssetSHA256.lowercased() else {
                    throw CharacterVocalBlendShapeError.hashMismatch(
                        resource: assetURL.lastPathComponent,
                        expected: descriptor.sourceAssetSHA256,
                        actual: assetHash
                    )
                }

                var offsetPayload: SingleBlendShapeOffsetPayload?
                if let path = descriptor.offsetPayloadResourcePath,
                   let expectedHash = descriptor.offsetPayloadSHA256,
                   let meshCount = descriptor.offsetPayloadMeshCount,
                   let recordCount = descriptor.offsetPayloadRecordCount {
                    let pathURL = URL(fileURLWithPath: path)
                    let payloadURL = try Self.resourceURL(
                        bundle: bundle,
                        name: pathURL.deletingPathExtension().lastPathComponent,
                        extension: pathURL.pathExtension,
                        subdirectory: "CharacterLibrary/FacialPerformance"
                    )
                    let data = try Data(contentsOf: payloadURL)
                    let actualHash = Self.sha256(data: data)
                    guard actualHash == expectedHash.lowercased() else {
                        throw CharacterVocalBlendShapeError.hashMismatch(
                            resource: payloadURL.lastPathComponent,
                            expected: expectedHash,
                            actual: actualHash
                        )
                    }
                    offsetPayload = try SingleBlendShapeOffsetPayload(
                        data: data,
                        expectedMeshCount: meshCount,
                        expectedRecordCount: recordCount
                    )
                }
                return CharacterVocalBlendShapeResources(
                    descriptor: descriptor,
                    offsetPayload: offsetPayload
                )
            }.value
            result = .success(loaded)
        } catch {
            result = .failure(error)
        }
        cached = result
        return try result.get()
    }

    private nonisolated static func resourceURL(
        bundle: Bundle,
        name: String,
        extension fileExtension: String,
        subdirectory: String?
    ) throws -> URL {
        if let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? bundle.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        throw CharacterVocalBlendShapeError.missingResource("\(name).\(fileExtension)")
    }

    private nonisolated static func sha256(url: URL) throws -> String {
        try sha256(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private nonisolated static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
