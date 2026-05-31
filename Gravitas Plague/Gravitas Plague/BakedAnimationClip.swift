import Foundation

enum ClipID: CaseIterable, Hashable {
    case idle
    case turnRight
    case unstableWalk
}

struct BakedAnimationClip: Hashable {
    let id: ClipID
    let fileBaseName: String
    let fileExtension: String
    let looping: Bool
    let configuredDuration: TimeInterval?

    var fullFileName: String {
        "\(fileBaseName).\(fileExtension)"
    }
}

extension BakedAnimationClip {
    nonisolated static let phaseOneClips: [BakedAnimationClip] = [
        BakedAnimationClip(
            id: .idle,
            fileBaseName: "idle-01",
            fileExtension: "usdz",
            looping: true,
            configuredDuration: nil
        ),
        BakedAnimationClip(
            id: .turnRight,
            fileBaseName: "idle-turn-right",
            fileExtension: "usdz",
            looping: false,
            configuredDuration: 1.2
        ),
        BakedAnimationClip(
            id: .unstableWalk,
            fileBaseName: "unstable-walk",
            fileExtension: "usdz",
            looping: true,
            configuredDuration: nil
        )
    ]
}
