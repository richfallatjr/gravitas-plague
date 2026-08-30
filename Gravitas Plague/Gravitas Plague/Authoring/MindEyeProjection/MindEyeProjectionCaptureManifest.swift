#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated struct MindEyeProjectionCaptureManifest: Codable, Sendable, Equatable {
    struct Output: Codable, Sendable, Equatable {
        let role: String
        let filename: String
        let width: Int
        let height: Int
        let bitsPerChannel: Int
        let colorSpace: String
        let alphaMode: String
        let byteCount: Int
        let SHA256: String
    }

    let schemaVersion: Int
    let captureID: String
    let repositoryCommit: String
    let worktreeWasDirty: Bool
    let appBuildConfiguration: String
    let SDKBuild: String
    let simulatorRuntime: String
    let simulatorDevice: String
    let profileID: String
    let profileSHA256: String
    let cameraID: String
    let cameraSHA256: String
    let targetSHA256: String
    let subjectAssetSHA256: String
    let heavenEXRSHA256: String
    let sceneDefinitionSHA256: String
    let sourceWidth: Int
    let sourceHeight: Int
    let viewportWidth: Int
    let viewportHeight: Int
    let captureState: String
    let mediaTimeSeconds: Double
    let animationAdvancedFrames: Int
    let beautyPixelFormat: String
    let maskPixelFormat: String
    let maskCoverageFraction: Double
    let maskBoundingBoxPixels: [Int]
    let maskCenterErrorPixels: [Double]
    let outputs: [Output]
}
#endif
