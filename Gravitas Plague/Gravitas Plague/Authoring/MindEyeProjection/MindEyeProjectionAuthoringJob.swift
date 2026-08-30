#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated struct MindEyeProjectionAuthoringJob: Sendable, Equatable {
    let configuration: MindEyeProjectionAuthoringLaunchConfiguration
}
#endif
