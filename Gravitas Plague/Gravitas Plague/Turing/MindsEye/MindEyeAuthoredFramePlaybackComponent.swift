import Foundation
import RealityKit

nonisolated struct MindEyeAuthoredFramePlaybackComponent: TransientComponent {
    let registrationToken: UUID
    var isPaused: Bool

    init(registrationToken: UUID, isPaused: Bool) {
        self.registrationToken = registrationToken
        self.isPaused = isPaused
    }
}
