import Foundation
import RealityKit

nonisolated struct MindEyeMotionComponent: TransientComponent {
    let registrationToken: UUID
    var runtimeState: MindEyeMotionRuntimeState
    let tuning: MindEyeKeepAliveTuning
    var isPaused: Bool
    var isActive: Bool

    init(
        registrationToken: UUID,
        rootSeed: UInt64,
        tuning: MindEyeKeepAliveTuning
    ) {
        self.registrationToken = registrationToken
        runtimeState = MindEyeMotionRuntimeState(
            rootSeed: rootSeed,
            tuning: tuning
        )
        self.tuning = tuning
        isPaused = false
        isActive = true
    }
}
