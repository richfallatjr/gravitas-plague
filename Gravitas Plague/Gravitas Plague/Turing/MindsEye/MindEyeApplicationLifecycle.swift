import Foundation
import SwiftUI

nonisolated enum MindEyeApplicationLifecycleState:
    String,
    Sendable,
    Equatable
{
    case active
    case inactive
    case background

    init(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .background
        }
    }
}

nonisolated struct MindEyeApplicationLifecycleTransition:
    Sendable,
    Equatable
{
    let previous: MindEyeApplicationLifecycleState
    let current: MindEyeApplicationLifecycleState
    let generation: UInt64
}
