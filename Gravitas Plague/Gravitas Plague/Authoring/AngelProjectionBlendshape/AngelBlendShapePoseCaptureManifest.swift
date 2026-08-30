#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated struct AngelBlendShapePoseCaptureManifest: Codable, Sendable, Equatable {
    struct Pose: Codable, Sendable, Equatable {
        let semanticPose: MindEyeMouthPose
        let geometryWeight: Float
        let beautyFilename: String
        let coverageFilename: String
    }

    let schemaVersion: Int
    let blendShapeName: String
    let projectorCameraSHA256: String
    let poses: [Pose]
    let teethGeometryAlias: MindEyeMouthPose
    let unionMaskFilename: String
}
#endif
