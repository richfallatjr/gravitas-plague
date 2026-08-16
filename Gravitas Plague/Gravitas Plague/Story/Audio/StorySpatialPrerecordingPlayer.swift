import Foundation
import RealityKit

@MainActor
final class StorySpatialPrerecordingPlayer {
    private var controller: AudioPlaybackController?

    func stop(reason: String) {
        controller?.stop()
        controller = nil
        print("[StoryCinematicPR] stopped reason=\(reason)")
    }

    var activePlaybackControllerCount: Int {
        controller == nil ? 0 : 1
    }
}
