import Foundation

enum HordePortalMirrorRetentionPolicy: String, Sendable {
    case retainAfterExit
    case destroyAfterExit
}

enum HordePortalMirrorOptimizationSettings {
    /// Inclusive cutoff. Waves 1...3 retain mirrors; wave 4+ destroys them after ingress.
    static let retainMirrorsThroughWave: Int = 3

    static func retentionPolicy(
        forWave wave: Int
    ) -> HordePortalMirrorRetentionPolicy {
        wave <= retainMirrorsThroughWave
            ? .retainAfterExit
            : .destroyAfterExit
    }
}
