import Foundation

nonisolated struct Chapter03AngelBlendShapeDescriptor: Codable, Sendable, Equatable {
    struct PoseWeights: Codable, Sendable, Equatable {
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

    struct Response: Codable, Sendable, Equatable {
        let openingHalfLifeSeconds: Float
        let closingHalfLifeSeconds: Float
        let crossingHalfLifeSeconds: Float
        let maximumDeltaTimeSeconds: Float
        let assignmentEpsilon: Float

        var runtimeValue: Chapter03AngelBlendShapeResponse {
            Chapter03AngelBlendShapeResponse(
                openingHalfLifeSeconds: openingHalfLifeSeconds,
                closingHalfLifeSeconds: closingHalfLifeSeconds,
                crossingHalfLifeSeconds: crossingHalfLifeSeconds,
                maximumDeltaTimeSeconds: maximumDeltaTimeSeconds,
                assignmentEpsilon: assignmentEpsilon
            )
        }
    }

    let schemaVersion: Int
    let descriptorID: String
    let assetResourceName: String
    let assetExtension: String
    let assetSHA256: String
    let blendShapeName: String
    let offsetPayloadResourcePath: String
    let offsetPayloadSHA256: String
    let offsetPayloadMeshCount: Int
    let offsetPayloadRecordCount: Int
    let requiresProjectionReady: Bool
    let poseWeights: PoseWeights
    let response: Response
    let fallbackWeight: Float
    let allowedWeightRange: [Float]

    func validate() throws {
        guard schemaVersion == 1 else {
            throw Chapter03AngelBlendShapeError.invalidDescriptor("schemaVersion")
        }
        guard descriptorID == "chapter03.angel.jawOpenProjection.v1",
              assetResourceName == "angel_posed_01",
              assetExtension == "usdz",
              blendShapeName == "jawOpenProjection",
              offsetPayloadResourcePath ==
                "Turing/Chapter03/AngelProjection/angel_jaw_open_projection_offsets.bin",
              offsetPayloadSHA256.count == 64,
              offsetPayloadSHA256.allSatisfy(\.isHexDigit),
              offsetPayloadMeshCount == 1,
              offsetPayloadRecordCount == 5_721,
              requiresProjectionReady,
              assetSHA256.count == 64,
              assetSHA256.allSatisfy(\.isHexDigit) else {
            throw Chapter03AngelBlendShapeError.invalidDescriptor("identity")
        }
        let expected: [(MindEyeMouthPose, Float)] = [
            (.rest, 0), (.teeth, 0), (.small, 0.33),
            (.round, 0.5), (.wide, 1),
        ]
        guard expected.allSatisfy({ poseWeights.weight(for: $0.0) == $0.1 }) else {
            throw Chapter03AngelBlendShapeError.invalidDescriptor("poseWeights")
        }
        guard fallbackWeight == 0,
              allowedWeightRange == [0, 1],
              response.openingHalfLifeSeconds.isFinite,
              response.closingHalfLifeSeconds.isFinite,
              response.crossingHalfLifeSeconds.isFinite,
              response.maximumDeltaTimeSeconds.isFinite,
              response.assignmentEpsilon.isFinite,
              response.openingHalfLifeSeconds > 0,
              response.closingHalfLifeSeconds > 0,
              response.crossingHalfLifeSeconds > 0,
              response.maximumDeltaTimeSeconds > 0,
              response.maximumDeltaTimeSeconds <= 0.1,
              response.assignmentEpsilon > 0,
              response.assignmentEpsilon <= 0.01 else {
            throw Chapter03AngelBlendShapeError.invalidDescriptor("response")
        }
    }
}
