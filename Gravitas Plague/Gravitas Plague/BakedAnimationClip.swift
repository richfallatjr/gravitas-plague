import Foundation

enum ClipID: CaseIterable, Hashable {
    case idle
    case turnRight01
    case turnRight02
    case unstableWalk
}

struct BakedAnimationClip: Hashable {
    let id: ClipID
    let fileBaseName: String
    let fileExtension: String

    var fullFileName: String {
        "\(fileBaseName).\(fileExtension)"
    }

    var assetKey: String {
        fullFileName
    }
}

struct PhaseOneSequenceStep: Hashable {
    let clipID: ClipID

    /// Number of times RealityKit should play the animation resource.
    /// The USDZ animation range still owns the timing.
    let repeatCount: Int

    /// Move the persistent root in world space while this animation is playing.
    let translatesRootWhilePlaying: Bool

    /// Commit gameplay yaw after the clip fully completes.
    let commitRightTurnYawOnCompletion: Bool
}

extension BakedAnimationClip {
    nonisolated static let phaseOneClips: [BakedAnimationClip] = [
        BakedAnimationClip(
            id: .idle,
            fileBaseName: "idle-01",
            fileExtension: "usdz"
        ),

        BakedAnimationClip(
            id: .turnRight01,
            fileBaseName: "idle-turn-right-01",
            fileExtension: "usdz"
        ),

        BakedAnimationClip(
            id: .turnRight02,
            fileBaseName: "idle-turn-right-02",
            fileExtension: "usdz"
        ),

        BakedAnimationClip(
            id: .unstableWalk,
            fileBaseName: "unstable-walk",
            fileExtension: "usdz"
        )
    ]
}

extension PhaseOneSequenceStep {
    nonisolated static let phaseOneLoop: [PhaseOneSequenceStep] = [
        PhaseOneSequenceStep(
            clipID: .idle,
            repeatCount: 1,
            translatesRootWhilePlaying: false,
            commitRightTurnYawOnCompletion: false
        ),

        PhaseOneSequenceStep(
            clipID: .turnRight01,
            repeatCount: 1,
            translatesRootWhilePlaying: false,
            commitRightTurnYawOnCompletion: true
        ),

        PhaseOneSequenceStep(
            clipID: .turnRight02,
            repeatCount: 1,
            translatesRootWhilePlaying: false,
            commitRightTurnYawOnCompletion: true
        ),

        PhaseOneSequenceStep(
            clipID: .unstableWalk,
            repeatCount: 1,
            translatesRootWhilePlaying: true,
            commitRightTurnYawOnCompletion: false
        )
    ]
}
