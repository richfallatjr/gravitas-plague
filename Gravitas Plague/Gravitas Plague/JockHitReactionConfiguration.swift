import Foundation
import simd

enum JockHitSide: String, Equatable, Hashable, Codable {
    case left
    case right

    var opposite: JockHitSide {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        }
    }
}

enum JockHitSideSelectionMode: String, Equatable, Codable {
    case nearestFaceZone
    case handChirality
}

enum JockHitDamageLevel: String, Equatable, Hashable, CaseIterable, Codable, Comparable {
    case light
    case medium
    case hard
    case death

    var rank: Int {
        switch self {
        case .light:
            return 0
        case .medium:
            return 1
        case .hard:
            return 2
        case .death:
            return 3
        }
    }

    static func < (
        lhs: JockHitDamageLevel,
        rhs: JockHitDamageLevel
    ) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct JockHitBucketKey: Equatable, Hashable {
    let side: JockHitSide
    let damageLevel: JockHitDamageLevel
}

struct JockHitReactionConfiguration: Equatable {
    let enabled: Bool

    let sideSelectionMode: JockHitSideSelectionMode

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

    /// After this many accepted hits, play a terminal death clip.
    let deathHitCount: Int
    let deathClipIDs: [String]

    /// Side-specific sub-animation overlays triggered by detected face side.
    let headSnapSubAnimationBySide: [JockHitSide: [String]]

    /// Allows hard hits to vary across hard, medium, and light same-side clips.
    let includeLowerDamageClipsForHigherDamage: Bool

    /// Avoids picking the same clip twice in a row when a bucket has alternatives.
    let avoidImmediateRepeat: Bool

    /// Maps detected face-side hits to the opposite authored clip-side bucket.
    let invertHitClipSide: Bool

    let clipBuckets: [JockHitBucketKey: [String]]

    static let phaseOne = JockHitReactionConfiguration(
        enabled: true,

        sideSelectionMode: .handChirality,

        faceCenterHeightMeters: 1.45,
        faceZoneRadiusMeters: 0.18,
        faceSideOffsetMeters: 0.13,
        maxHitDistanceMeters: 0.24,

        lightVelocityThreshold: 0.55,
        mediumVelocityThreshold: 1.05,
        hardVelocityThreshold: 2.25,
        deathVelocityThreshold: 999.0,

        perHandCooldownSeconds: 0.45,
        globalHitCooldownSeconds: 0.65,

        knockbackMetersLight: 0.08,
        knockbackMetersMedium: 0.18,
        knockbackMetersHard: 0.35,
        knockbackMetersDeath: 0.7,

        stunSecondsLight: 0.35,
        stunSecondsMedium: 0.85,
        stunSecondsHard: 1.25,
        stunSecondsDeath: 999.0,

        deathHitCount: 10,

        deathClipIDs: [
            "dead_fall_forward",
            "dead_fall_backward_01",
            "dead_fall_backward_02"
        ],

        headSnapSubAnimationBySide: [
            .right: [
                "head_snap_right",
                "head_snap_right_v001"
            ],
            .left: [
                "head_snap_left",
                "head_snap_left_v001"
            ]
        ],

        includeLowerDamageClipsForHigherDamage: true,
        avoidImmediateRepeat: true,
        invertHitClipSide: false,

        clipBuckets: [
            JockHitBucketKey(side: .left, damageLevel: .medium): [
                "hit_medium_left_01",
                "hit_medium_left_02",
                "hit_medium_left"
            ],
            JockHitBucketKey(side: .right, damageLevel: .medium): [
                "hit_medium_right_01",
                "hit_medium_right_02",
                "hit_medium_right"
            ],
            JockHitBucketKey(side: .left, damageLevel: .light): [],
            JockHitBucketKey(side: .right, damageLevel: .light): [],
            JockHitBucketKey(side: .left, damageLevel: .hard): [
                "hit_hard_left_01"
            ],
            JockHitBucketKey(side: .right, damageLevel: .hard): [
                "hit_hard_right_01"
            ],
            JockHitBucketKey(side: .left, damageLevel: .death): [
                "dead_fall_forward",
                "dead_fall_backward_01",
                "dead_fall_backward_02"
            ],
            JockHitBucketKey(side: .right, damageLevel: .death): [
                "dead_fall_forward",
                "dead_fall_backward_01",
                "dead_fall_backward_02"
            ]
        ]
    )

    func damageLevel(for velocity: Float) -> JockHitDamageLevel? {
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
