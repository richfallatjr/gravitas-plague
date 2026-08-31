import Foundation

nonisolated struct MindEyeProjectionProfile: Codable, Sendable, Equatable {
    static let supportedSchemaVersion = 2

    enum ReceiverMaskConvention: String, Codable, Sendable, Equatable {
        case darkProjectsLightSuppresses
    }

    struct ReceiverUVMask: Codable, Sendable, Equatable {
        let resourcePath: String
        let SHA256: String
        let width: Int
        let height: Int
        let bitsPerChannel: Int
        let colorSpace: String
        let convention: ReceiverMaskConvention
        let UVSetName: String
        let UVSetIndex: Int

        func validate() throws {
            guard MindEyeSafeRelativePath.validates(resourcePath),
                  SHA256.count == 64,
                  SHA256.allSatisfy(\.isHexDigit),
                  width == 1_024,
                  height == 1_024,
                  [8, 16].contains(bitsPerChannel),
                  colorSpace == "linearData",
                  convention == .darkProjectsLightSuppresses,
                  UVSetName == "primvars:st",
                  UVSetIndex == 0 else {
                throw MindEyeProjectionError.invalidReceiverMask(
                    "profile receiver-mask contract is invalid"
                )
            }
        }
    }

    let schemaVersion: Int
    let profileID: String
    let subjectAssetName: String
    let sceneSequenceID: String
    let sceneContentRevision: String
    let sourceWidth: Int
    let sourceHeight: Int
    let viewportWidth: Int
    let viewportHeight: Int
    let cropOriginX: Int
    let cropOriginY: Int
    let cameraResourcePath: String
    let targetResourcePath: String
    let plateManifestResourcePath: String
    let importedPBRContractResourcePath: String
    let materialParityQualificationResourcePath: String
    let projectionReceiverUVMask: ReceiverUVMask
    let projectionCompositeAlphaSemantics: String
    let projectionEmissionGain: Float
    let albedoSuppression: Float
    let specularSuppression: Float
    let fullQualityAngleDegrees: Float
    let zeroProjectionAngleDegrees: Float

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw MindEyeProjectionError.unsupportedSchemaVersion(schemaVersion)
        }
        guard profileID == "angel_head_v1",
              subjectAssetName == "angel_posed_01.usdz" else {
            throw MindEyeProjectionError.invalidProfileID(profileID)
        }
        guard sourceWidth == 1_728, sourceHeight == 1_728,
              viewportWidth == 1_440, viewportHeight == 1_440,
              cropOriginX == 144, cropOriginY == 144,
              sourceWidth * sourceHeight == 2_304 * 1_296,
              viewportWidth * viewportHeight == 1_920 * 1_080 else {
            throw MindEyeProjectionError.invalidSquarePixelBudget
        }
        guard MindEyeSafeRelativePath.validates(cameraResourcePath),
              MindEyeSafeRelativePath.validates(targetResourcePath),
              MindEyeSafeRelativePath.validates(plateManifestResourcePath),
              MindEyeSafeRelativePath.validates(importedPBRContractResourcePath),
              MindEyeSafeRelativePath.validates(materialParityQualificationResourcePath) else {
            throw MindEyeProjectionError.missingResource(
                "unsafe projection profile path"
            )
        }
        try projectionReceiverUVMask.validate()
        guard projectionCompositeAlphaSemantics == "sourceOverOnly",
              projectionEmissionGain.isFinite,
              (0.25...2).contains(projectionEmissionGain),
              albedoSuppression.isFinite, (0...1).contains(albedoSuppression),
              specularSuppression.isFinite, (0...1).contains(specularSuppression) else {
            throw MindEyeProjectionError.invalidMaterialControls
        }
        guard fullQualityAngleDegrees >= 0,
              zeroProjectionAngleDegrees > fullQualityAngleDegrees,
              zeroProjectionAngleDegrees <= 70 else {
            throw MindEyeProjectionError.invalidViewCone
        }
    }
}

nonisolated enum MindEyeCompositorCanvasProfile: Sendable, Equatable {
    case landscapePortraitCard
    case squareFacialProjection

    var sourceDimensions: SIMD2<Int32> {
        switch self {
        case .landscapePortraitCard: SIMD2(2_304, 1_296)
        case .squareFacialProjection: SIMD2(1_728, 1_728)
        }
    }

    var outputDimensions: SIMD2<Int32> {
        switch self {
        case .landscapePortraitCard: SIMD2(1_920, 1_080)
        case .squareFacialProjection: SIMD2(1_440, 1_440)
        }
    }

    var cropOrigin: SIMD2<Int32> {
        switch self {
        case .landscapePortraitCard: SIMD2(192, 108)
        case .squareFacialProjection: SIMD2(144, 144)
        }
    }

    var permitsInternalMotion: Bool { self == .landscapePortraitCard }
}
