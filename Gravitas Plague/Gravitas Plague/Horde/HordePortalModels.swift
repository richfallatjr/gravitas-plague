import Foundation
import RealityKit
import simd

enum HordePortalLocalAxes {
    static let right = SIMD3<Float>(1, 0, 0)
    static let up = SIMD3<Float>(0, 1, 0)
    static let outToRoom = SIMD3<Float>(0, 0, 1)
    static let characterForward = SIMD3<Float>(0, 0, -1)
}

enum HordePortalEntranceSide: String, Codable {
    case left
    case right

    var startLocalXSign: Float {
        switch self {
        case .left:
            return -1
        case .right:
            return 1
        }
    }

    var walkDirectionLocalX: Float {
        switch self {
        case .left:
            return 1
        case .right:
            return -1
        }
    }
}

enum HordePortalTurnResolver {
    static func signedYawRadians(
        from current: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> Float {
        let a = normalizeSafe(
            SIMD3<Float>(current.x, 0, current.z),
            fallback: HordePortalLocalAxes.outToRoom
        )

        let b = normalizeSafe(
            SIMD3<Float>(target.x, 0, target.z),
            fallback: HordePortalLocalAxes.outToRoom
        )

        let crossY = simd_cross(a, b).y
        let dot = simd_dot(a, b)

        return atan2(crossY, dot)
    }

    static func clipID(
        from current: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> String {
        let yaw = signedYawRadians(
            from: current,
            to: target
        )

        return yaw >= 0 ? "turn_left_90" : "turn_right_90"
    }
}

struct HordePortalApertureProfile: Codable, Equatable {
    var bottomWidth: Float
    var maxHeight: Float
    var leftHeight: Float
    var rightHeight: Float
    var leftTopLean: Float
    var rightTopLean: Float
    var topPeakOffset: Float
    var topSagOffset: Float
    var topSamples: Int

    static func random(
        baseWidth: Float,
        baseHeight: Float,
        seed: UInt64
    ) -> HordePortalApertureProfile {
        var rng = SeededRNG(seed: seed)

        let leftHeight = baseHeight * Float.random(in: 0.86...1.08, using: &rng)
        let rightHeight = baseHeight * Float.random(in: 0.86...1.08, using: &rng)
        let maxHeight = max(leftHeight, rightHeight) + 0.08

        return HordePortalApertureProfile(
            bottomWidth: baseWidth,
            maxHeight: maxHeight,
            leftHeight: leftHeight,
            rightHeight: rightHeight,
            leftTopLean: Float.random(in: -0.16...0.08, using: &rng),
            rightTopLean: Float.random(in: -0.08...0.16, using: &rng),
            topPeakOffset: Float.random(in: 0.03...0.18, using: &rng),
            topSagOffset: Float.random(in: -0.10...0.06, using: &rng),
            topSamples: 7
        )
    }

    var bottomY: Float {
        -maxHeight * 0.5
    }

    var leftBottom: SIMD2<Float> {
        SIMD2<Float>(
            -bottomWidth * 0.5,
            bottomY
        )
    }

    var rightBottom: SIMD2<Float> {
        SIMD2<Float>(
            bottomWidth * 0.5,
            bottomY
        )
    }

    var leftTop: SIMD2<Float> {
        SIMD2<Float>(
            -bottomWidth * 0.5 + leftTopLean,
            bottomY + leftHeight
        )
    }

    var rightTop: SIMD2<Float> {
        SIMD2<Float>(
            bottomWidth * 0.5 + rightTopLean,
            bottomY + rightHeight
        )
    }
}

struct HordePortal: Identifiable {
    let id: UUID
    let waveCreated: Int
    let wallID: UUID
    var placement: DoorPlacement
    var apertureProfile: HordePortalApertureProfile
    let root: Entity
    let portalWorldRoot: Entity
    let portalPlane: ModelEntity
    var resolvedFloorWorldY: Float?
    var worldCenter: SIMD3<Float>
    var bearingFromPlayerRadians: Float
    var entranceCount: Int = 0

    var portalFloorLocalY: Float {
        -placement.height * 0.5
    }

    @MainActor
    func localRootYForEnemy(
        enemy: JockRetargetTestController
    ) -> Float {
        portalFloorLocalY + enemy.groundingProfile.rootYOffsetFromFloor
    }
}

enum HordePortalRequiredClips {
    static let clipIDs = [
        "turn_left_90",
        "turn_right_90"
    ]

    static func validate(
        availableClipIDs: Set<String>
    ) {
        for id in clipIDs {
            if availableClipIDs.contains(id) {
                print("[HordePortal] found required clip \(id)")
            } else {
                print("[HordePortal] ERROR missing required clip \(id)")
            }
        }
    }
}

struct HordePortalPlacementCandidate {
    let wall: WallCandidate
    let placement: DoorPlacement
    let worldCenter: SIMD3<Float>
    let bearingRadians: Float
    let nearestPortalDistance: Float
    let nearestBearingGap: Float
    let score: Float
}

enum HordePortalPlacementTuning {
    static let minSpacingMeters: Float = 0.91
    static let preferredSpacingMeters: Float = 1.52
    static let candidateCountPerWall = 14
    static let angularBinCount = 12
}

private func normalizeSafe(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length > 0.0001 else {
        return fallback
    }

    return vector / length
}
