import Foundation

struct JockAttackConfiguration: Equatable {
    let enabled: Bool

    let attackProximityMeters: Float
    let resumeFollowDistanceMeters: Float

    let aggressiveDelayMinSeconds: TimeInterval
    let aggressiveDelayMaxSeconds: TimeInterval

    let playerDangerSphereRadiusMeters: Float

    let exposureMax: Int
    let failOnExposureMax: Bool

    let attackClipIDs: [String]

    let escalationDamageLevels: Set<JockHitDamageLevel>

    static let phaseOne = JockAttackConfiguration(
        enabled: true,

        attackProximityMeters: 0.70,
        resumeFollowDistanceMeters: 0.95,

        aggressiveDelayMinSeconds: 0.0,
        aggressiveDelayMaxSeconds: 0.4,

        playerDangerSphereRadiusMeters: 0.30,

        exposureMax: 100,
        failOnExposureMax: false,

        attackClipIDs: [
            "charged-slash-left",
            "charged-slash-right"
        ],

        escalationDamageLevels: [
            .hard,
            .death
        ]
    )

    func randomAggressiveDelay() -> TimeInterval {
        Double.random(
            in: aggressiveDelayMinSeconds...aggressiveDelayMaxSeconds
        )
    }
}
