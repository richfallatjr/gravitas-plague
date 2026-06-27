import Foundation

enum HordeEnemyBrainSettings {
    /// 0.25 = 4 off-main ray/probe decisions per second.
    static let decisionIntervalSeconds: TimeInterval = 0.25

    /// Never queue multiple brain jobs. If one is still running,
    /// keep using the last command.
    static let allowBrainBacklog = false

    static let rayBodyPaddingMeters: Float = 0.08
    static let blockedForwardBlend: Float = 0.35
    static let blockedLateralBlend: Float = 1.0
    static let minimumTravelBudgetMeters: Float = 0.08
    static let maximumTravelBudgetMeters: Float = 0.75
}
