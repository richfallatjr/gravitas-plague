import Foundation

nonisolated struct MindEyeProjectionQualificationIdentities: Sendable, Equatable {
    let subjectAssetSHA256: String
    let profileSHA256: String
    let cameraSHA256: String
    let targetSHA256: String
    let importedPBRContractSHA256: String
}

nonisolated struct MindEyeProjectionMaterialParityQualification: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let qualificationID: String
    let subjectAssetSHA256: String
    let profileSHA256: String
    let cameraSHA256: String
    let targetSHA256: String
    let importedPBRContractSHA256: String
    let graphVersion: String
    let SDKBuild: String
    let renderWidth: Int
    let renderHeight: Int
    let maskPixelCount: Int
    let RMSELinearRGB: Double
    let p99AbsoluteErrorLinearRGB: Double
    let maximumAbsoluteErrorLinearRGB: Double
    let PSNRDecibels: Double
    let passed: Bool

    func validate(identities: MindEyeProjectionQualificationIdentities) throws {
        guard schemaVersion == 1,
              qualificationID == "angel_head_v1.material-parity",
              subjectAssetSHA256 == identities.subjectAssetSHA256,
              profileSHA256 == identities.profileSHA256,
              cameraSHA256 == identities.cameraSHA256,
              targetSHA256 == identities.targetSHA256,
              importedPBRContractSHA256 == identities.importedPBRContractSHA256,
              graphVersion == "angel-camera-projector-uv-receiver/2",
              renderWidth >= 512,
              renderHeight >= 512,
              maskPixelCount > 0,
              RMSELinearRGB <= 0.0075,
              p99AbsoluteErrorLinearRGB <= 0.020,
              maximumAbsoluteErrorLinearRGB <= 0.080,
              PSNRDecibels >= 42,
              passed else {
            throw MindEyeProjectionError.materialParityUnqualified
        }
    }
}
