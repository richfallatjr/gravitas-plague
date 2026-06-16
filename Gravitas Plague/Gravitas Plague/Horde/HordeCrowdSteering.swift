import Foundation
import simd

enum HordeCrowdSteeringMode: String {
    case directToUser
    case flanking
    case reGoalToUser
}

struct HordeCrowdSteeringState {
    var mode: HordeCrowdSteeringMode = .directToUser
    var steerAngleRadians: Float = 0
    var lockedRotateSign: Float = 0
    var nextSolveTime: TimeInterval = 0
    var lastGoalBlocked = false
    var lastForwardBlocked = false

    /// Debug only. Never used for movement.
    var debugGoalBlockerName: String?
    var debugForwardBlockerName: String?
}

enum HordeCrowdSteeringSettings {
    static let solveIntervalMin: TimeInterval = 0.08
    static let solveIntervalMax: TimeInterval = 0.14
    static let rotationStepDegrees: Float = 5.0
    static let reGoalDegreesPerSecond: Float = 90.0
    static let forwardRayLengthMeters: Float = 1.15
    static let rayOriginHeightFraction: Float = 0.45
    static let attackRangeBufferMeters: Float = 0.12
    static let userMoveBreakAttackMeters: Float = 0.35
    static let rightOfWayDistanceEpsilon: Float = 0.05
}

struct HordeCrowdRayValidation {
    let blocked: Bool
    let debugBlockerName: String?
}

enum HordeCrowdEnemyRayMath {
    static func rayVsOBB2D(
        origin: SIMD2<Float>,
        direction: SIMD2<Float>,
        maxDistance: Float,
        center: SIMD2<Float>,
        axisX: SIMD2<Float>,
        axisY: SIMD2<Float>,
        halfX: Float,
        halfY: Float
    ) -> Float? {
        var tMin: Float = 0
        var tMax: Float = maxDistance

        let delta = origin - center
        let localOriginX = simd_dot(delta, axisX)
        let localOriginY = simd_dot(delta, axisY)
        let localDirX = simd_dot(direction, axisX)
        let localDirY = simd_dot(direction, axisY)

        guard clipSlab(
            origin: localOriginX,
            direction: localDirX,
            min: -halfX,
            max: halfX,
            tMin: &tMin,
            tMax: &tMax
        ) else {
            return nil
        }

        guard clipSlab(
            origin: localOriginY,
            direction: localDirY,
            min: -halfY,
            max: halfY,
            tMin: &tMin,
            tMax: &tMax
        ) else {
            return nil
        }

        if tMin < 0 {
            return max(0, tMax)
        }

        return tMin <= maxDistance ? tMin : nil
    }

    private static func clipSlab(
        origin: Float,
        direction: Float,
        min: Float,
        max: Float,
        tMin: inout Float,
        tMax: inout Float
    ) -> Bool {
        let epsilon: Float = 0.00001

        if abs(direction) < epsilon {
            return origin >= min && origin <= max
        }

        let invD = 1.0 / direction
        var t1 = (min - origin) * invD
        var t2 = (max - origin) * invD

        if t1 > t2 {
            swap(&t1, &t2)
        }

        tMin = Swift.max(tMin, t1)
        tMax = Swift.min(tMax, t2)

        return tMin <= tMax
    }
}

@MainActor
func validateEnemyBodyRay(
    selfEnemy: JockRetargetTestController,
    originWorld: SIMD3<Float>,
    directionWorld: SIMD3<Float>,
    length: Float,
    headsetPosition: SIMD3<Float>,
    snapshots: [HordeEnemyCollisionSnapshot]
) -> HordeCrowdRayValidation {
    let selfID = selfEnemy.hordeBenchmarkID
    let origin = SIMD2<Float>(originWorld.x, originWorld.z)
    let direction = normalizeCrowdRay2(
        SIMD2<Float>(directionWorld.x, directionWorld.z),
        fallback: SIMD2<Float>(0, -1)
    )

    var bestDistance = Float.greatestFiniteMagnitude
    var bestName: String?

    for snapshot in snapshots {
        guard snapshot.enemyID != selfID else {
            continue
        }

        let other = snapshot.controller

        guard selfEnemy.shouldYieldToEnemy(
            other,
            headsetPosition: headsetPosition
        ) else {
            continue
        }

        guard let distance = HordeCrowdEnemyRayMath.rayVsOBB2D(
            origin: origin,
            direction: direction,
            maxDistance: length,
            center: SIMD2<Float>(
                snapshot.centerWorld.x,
                snapshot.centerWorld.z
            ),
            axisX: snapshot.rightXZ,
            axisY: snapshot.forwardXZ,
            halfX: snapshot.halfWidth,
            halfY: snapshot.halfDepth
        ) else {
            continue
        }

        if distance < bestDistance {
            bestDistance = distance
            bestName = "enemy:\(other.enemySeparationCharacterID):\(snapshot.enemyID.uuidString)"
        }
    }

    return HordeCrowdRayValidation(
        blocked: bestName != nil,
        debugBlockerName: bestName
    )
}

func crowdDistanceXZ(
    _ a: SIMD3<Float>,
    _ b: SIMD3<Float>
) -> Float {
    simd_length(
        SIMD2<Float>(
            a.x - b.x,
            a.z - b.z
        )
    )
}

func flatNormalize(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let flat = SIMD3<Float>(
        v.x,
        0,
        v.z
    )

    guard simd_length(flat) > 0.001 else {
        return fallback
    }

    return simd_normalize(flat)
}

func rotateFlat(
    _ v: SIMD3<Float>,
    radians: Float
) -> SIMD3<Float> {
    let c = cos(radians)
    let s = sin(radians)

    return flatNormalize(
        SIMD3<Float>(
            v.x * c - v.z * s,
            0,
            v.x * s + v.z * c
        ),
        fallback: v
    )
}

func signFloat(
    _ value: Float
) -> Float {
    value >= 0 ? 1 : -1
}

private func normalizeCrowdRay2(
    _ v: SIMD2<Float>,
    fallback: SIMD2<Float>
) -> SIMD2<Float> {
    let length = simd_length(v)

    guard length > 0.00001 else {
        return fallback
    }

    return v / length
}
