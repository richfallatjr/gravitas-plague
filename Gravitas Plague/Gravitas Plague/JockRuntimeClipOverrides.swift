import Foundation
import RealityKit
import simd

struct JockRuntimeClipOverrides: Codable, Equatable {
    let schema: String
    let clips: [String: JockRuntimeClipOverride]
}

struct JockRuntimeClipOverride: Codable, Equatable {
    let entryHeadingDegrees: Float
    let exitHeadingDegrees: Float
    let commitRootYawOnCompletion: Bool

    enum CodingKeys: String, CodingKey {
        case entryHeadingDegrees = "entry_heading_degrees"
        case exitHeadingDegrees = "exit_heading_degrees"
        case commitRootYawOnCompletion = "commit_root_yaw_on_completion"
    }

    nonisolated static let identity = JockRuntimeClipOverride(
        entryHeadingDegrees: 0,
        exitHeadingDegrees: 0,
        commitRootYawOnCompletion: false
    )

    var yawDeltaDegrees: Float {
        exitHeadingDegrees - entryHeadingDegrees
    }

    var entryVisualOffsetOrientation: simd_quatf {
        simd_quatf(
            angle: JockPoseMath.radians(-entryHeadingDegrees),
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    var exitVisualOffsetOrientation: simd_quatf {
        simd_quatf(
            angle: JockPoseMath.radians(-exitHeadingDegrees),
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    var rootYawDeltaOrientation: simd_quatf {
        simd_quatf(
            angle: JockPoseMath.radians(yawDeltaDegrees),
            axis: SIMD3<Float>(0, 1, 0)
        )
    }
}
