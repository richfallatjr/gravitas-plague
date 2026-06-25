import Foundation

enum HordePortalMirrorRetentionPolicy: String, Sendable {
    case retainAfterExit
    case destroyAfterExit
}

enum HordePortalMirrorOptimizationSettings {
    /// Inclusive cutoff. Waves 1...5 retain mirrors; wave 6+ destroys them after ingress.
    static let retainMirrorsThroughWave: Int = 5

    static func retentionPolicy(
        forWave wave: Int
    ) -> HordePortalMirrorRetentionPolicy {
        wave <= retainMirrorsThroughWave
            ? .retainAfterExit
            : .destroyAfterExit
    }
}
