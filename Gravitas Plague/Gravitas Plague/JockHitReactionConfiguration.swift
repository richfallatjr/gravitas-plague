import Foundation
import simd

enum JockHitSide: String, Equatable, Hashable, Codable {
    case left
    case right
}

enum JockHitDamageLevel: String, Equatable, Hashable, CaseIterable, Codable {
    case light
    case medium
    case hard
    case death
}

struct JockHitBucketKey: Equatable, Hashable {
    let side: JockHitSide
    let damageLevel: JockHitDamageLevel
}

struct JockHitReactionConfiguration: Equatable {
    let enabled: Bool

    let faceCenterHeightMeters: Float
    let faceZoneRadiusMeters: Float
    let faceSideOffsetMeters: Float
    let maxHitDistanceMeters: Float

    let lightVelocityThreshold: Float
    let mediumVelocityThreshold: Float
    let hardVelocityThreshold: Float
    let deathVelocityThreshold: Float

    let perHandCooldownSeconds: TimeInterval
    let globalHitCooldownSeconds: TimeInterval

    let knockbackMetersLight: Float
    let knockbackMetersMedium: Float
    let knockbackMetersHard: Float
    let knockbackMetersDeath: Float

    let stunSecondsLight: TimeInterval
    let stunSecondsMedium: TimeInterval
    let stunSecondsHard: TimeInterval
    let stunSecondsDeath: TimeInterval

    let clipBuckets: [JockHitBucketKey: [String]]

    static let phaseOne = JockHitReactionConfiguration(
        enabled: true,

        faceCenterHeightMeters: 1.45,
        faceZoneRadiusMeters: 0.18,
        faceSideOffsetMeters: 0.13,
        maxHitDistanceMeters: 0.24,

        lightVelocityThreshold: 0.55,
        mediumVelocityThreshold: 1.05,
        hardVelocityThreshold: 1.75,
        deathVelocityThreshold: 3.0,

        perHandCooldownSeconds: 0.45,
        globalHitCooldownSeconds: 0.65,

        knockbackMetersLight: 0.08,
        knockbackMetersMedium: 0.18,
        knockbackMetersHard: 0.35,
        knockbackMetersDeath: 0.7,

        stunSecondsLight: 0.35,
        stunSecondsMedium: 0.75,
        stunSecondsHard: 1.15,
        stunSecondsDeath: 2.0,

        clipBuckets: [
            JockHitBucketKey(side: .left, damageLevel: .medium): [
                "hit_medium_left_01",
                "hit_medium_left_02"
            ],
            JockHitBucketKey(side: .right, damageLevel: .medium): [
                "hit_medium_right_01",
                "hit_medium_right_02"
            ],
            JockHitBucketKey(side: .left, damageLevel: .light): [
                "hit_light_left_01"
            ],
            JockHitBucketKey(side: .right, damageLevel: .light): [
                "hit_light_right_01"
            ],
            JockHitBucketKey(side: .left, damageLevel: .hard): [
                "hit_hard_left_01"
            ],
            JockHitBucketKey(side: .right, damageLevel: .hard): [
                "hit_hard_right_01"
            ],
            JockHitBucketKey(side: .left, damageLevel: .death): [],
            JockHitBucketKey(side: .right, damageLevel: .death): []
        ]
    )

    func damageLevel(for velocity: Float) -> JockHitDamageLevel? {
        if velocity >= deathVelocityThreshold {
            return .death
        }

        if velocity >= hardVelocityThreshold {
            return .hard
        }

        if velocity >= mediumVelocityThreshold {
            return .medium
        }

        if velocity >= lightVelocityThreshold {
            return .light
        }

        return nil
    }

    func knockbackMeters(for damage: JockHitDamageLevel) -> Float {
        switch damage {
        case .light:
            return knockbackMetersLight
        case .medium:
            return knockbackMetersMedium
        case .hard:
            return knockbackMetersHard
        case .death:
            return knockbackMetersDeath
        }
    }

    func stunSeconds(for damage: JockHitDamageLevel) -> TimeInterval {
        switch damage {
        case .light:
            return stunSecondsLight
        case .medium:
            return stunSecondsMedium
        case .hard:
            return stunSecondsHard
        case .death:
            return stunSecondsDeath
        }
    }
}
