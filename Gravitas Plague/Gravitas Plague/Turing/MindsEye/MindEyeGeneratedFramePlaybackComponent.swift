import Foundation
import RealityKit

nonisolated struct MindEyeGeneratedFramePlaybackComponent: TransientComponent {
    let registrationToken: UUID
    var isPaused: Bool
}
