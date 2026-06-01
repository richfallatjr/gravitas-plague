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

    /// True for idle/walk. False for linear turn clips.
    let looping: Bool

    /// Only used if RealityKit fails to report a valid duration.
    /// Do not use this as the primary duration.
    let fallbackDuration: TimeInterval?

    /// Small safety delay after a one-shot reaches its reported duration.
    /// This helps make sure the final keyed frame/tail actually displays.
    let completionHold: TimeInterval

    var fullFileName: String {
        "\(fileBaseName).\(fileExtension)"
    }

    var assetKey: String {
        fullFileName
    }
}

extension BakedAnimationClip {
    nonisolated static let phaseOneClips: [BakedAnimationClip] = [
        BakedAnimationClip(
            id: .idle,
            fileBaseName: "idle-01",
            fileExtension: "usdz",
            looping: true,
            fallbackDuration: nil,
            completionHold: 0
        ),

        BakedAnimationClip(
            id: .turnRight01,
            fileBaseName: "idle-turn-right-01",
            fileExtension: "usdz",
            looping: false,
            fallbackDuration: 1.2,
            completionHold: 0.05
        ),

        BakedAnimationClip(
            id: .turnRight02,
            fileBaseName: "idle-turn-right-02",
            fileExtension: "usdz",
            looping: false,
            fallbackDuration: 1.2,
            completionHold: 0.05
        ),

        BakedAnimationClip(
            id: .unstableWalk,
            fileBaseName: "unstable-walk",
            fileExtension: "usdz",
            looping: true,
            fallbackDuration: nil,
            completionHold: 0
        )
    ]
}
