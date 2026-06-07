import Foundation
import RealityKit
import simd

struct JockPreparedTrack {
    let joint: String
    let runtimeIndex: Int
    let channel: String
    let keys: [JockAnimClip.Key]
    let sourceReferenceTranslation: SIMD3<Float>?
    let sourceReferenceRotation: simd_quatf?
    let sourceReferenceScale: SIMD3<Float>?
}

struct JockPreparedSubAnimation {
    let affectedJoints: [String]
    let affectedRuntimeIndices: [Int]
    let blendInDuration: TimeInterval
    let blendOutDuration: TimeInterval
}

struct JockPreparedClip {
    let clip: JockAnimClip
    let tracks: [JockPreparedTrack]
    let subAnimation: JockPreparedSubAnimation?

    let firstPose: [Transform]
    let lastPose: [Transform]

    var clipID: String {
        clip.clipID
    }

    var duration: TimeInterval {
        max(clip.timing.durationSeconds, 0.001)
    }

    var isSubAnimationOverride: Bool {
        clip.isSubAnimationOverride
    }
}
