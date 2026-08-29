import Foundation

nonisolated enum MindEyeVisualSuspensionReason:
    String,
    Sendable,
    Equatable,
    Hashable
{
    case audioPaused
    case applicationInactive
    case lifecycleTransition
}

@MainActor
protocol MindEyeVisualSuspensionControlling: AnyObject {
    func setVisualSuspension(
        _ reason: MindEyeVisualSuspensionReason,
        active: Bool,
        resampleAt: ContinuousClock.Instant?,
        diagnosticReason: String
    )
}
