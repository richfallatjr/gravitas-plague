#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated enum MindEyeProjectionRenderPass: String, Sendable, CaseIterable {
    case sceneBeauty = "scene-beauty"
    case faceBeauty = "face-beauty"
    case binaryMask = "binary-mask"
    case binaryCoverage = "binary-coverage"
}
#endif
