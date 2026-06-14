import Foundation
import RealityKit
import simd

@MainActor
final class HordePortalBackdropOrientationLock {
    private(set) var isLocked = false

    private var masterBehindYawRadians: Float = 0
    private let baseArtYawRadians: Float
    private let yawSign: Float = -1.0

    init(
        baseArtYawDegrees: Float = 0
    ) {
        self.baseArtYawRadians = baseArtYawDegrees * .pi / 180.0
    }

    func reset() {
        isLocked = false
        masterBehindYawRadians = 0

        print("[HordePortalBackdrop] orientation lock reset")
    }

    func applyBackdropOrientation(
        to backdropRoot: Entity,
        portalRoot: Entity,
        portalID: UUID,
        label: String
    ) {
        let behindDirection = Self.portalBehindDirectionWorld(
            portalRoot: portalRoot
        )

        applyBackdropOrientation(
            to: backdropRoot,
            behindDirection: behindDirection,
            portalID: portalID,
            label: label,
            source: "portal_root"
        )
    }

    func applyBackdropOrientation(
        to backdropRoot: Entity,
        wall: WallCandidate,
        portalID: UUID,
        label: String
    ) {
        var behind = -wall.normal
        behind.y = 0

        let behindDirection = Self.normalizeSafe(
            behind,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        applyBackdropOrientation(
            to: backdropRoot,
            behindDirection: behindDirection,
            portalID: portalID,
            label: label,
            source: "wall_normal"
        )
    }

    private func applyBackdropOrientation(
        to backdropRoot: Entity,
        behindDirection: SIMD3<Float>,
        portalID: UUID,
        label: String,
        source: String
    ) {
        let currentYaw = Self.yawRadians(
            forWorldDirection: behindDirection
        )

        if !isLocked {
            isLocked = true
            masterBehindYawRadians = currentYaw

            print(
                """
                [HordePortalBackdrop] master orientation locked
                  portalID: \(portalID)
                  label: \(label)
                  source: \(source)
                  masterBehindYawDegrees: \(Self.degrees(masterBehindYawRadians))
                  behindDirection: \(behindDirection)
                  deterministic: true
                """
            )
        }

        let relativeYaw = Self.shortestAngleDelta(
            from: masterBehindYawRadians,
            to: currentYaw
        )

        let appliedYaw =
            baseArtYawRadians +
            yawSign * relativeYaw

        backdropRoot.orientation = simd_quatf(
            angle: appliedYaw,
            axis: SIMD3<Float>(0, 1, 0)
        )

        print(
            """
            [HordePortalBackdrop] backdrop orientation applied
              portalID: \(portalID)
              label: \(label)
              source: \(source)
              currentBehindYawDegrees: \(Self.degrees(currentYaw))
              masterBehindYawDegrees: \(Self.degrees(masterBehindYawRadians))
              relativeYawDegrees: \(Self.degrees(relativeYaw))
              appliedBackdropYawDegrees: \(Self.degrees(appliedYaw))
              yawSign: \(yawSign)
              rotatesBackdropOnly: true
              portalWorldRootUnchanged: true
              enemyIngressUnaffected: true
            """
        )
    }

    private static func portalBehindDirectionWorld(
        portalRoot: Entity
    ) -> SIMD3<Float> {
        let matrix = portalRoot.transformMatrix(
            relativeTo: nil
        )

        let localPlusZWorld = SIMD3<Float>(
            matrix.columns.2.x,
            matrix.columns.2.y,
            matrix.columns.2.z
        )

        var behind = -localPlusZWorld
        behind.y = 0

        return normalizeSafe(
            behind,
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    private static func yawRadians(
        forWorldDirection direction: SIMD3<Float>
    ) -> Float {
        atan2(
            direction.x,
            direction.z
        )
    }

    private static func shortestAngleDelta(
        from a: Float,
        to b: Float
    ) -> Float {
        var delta = b - a

        while delta > .pi {
            delta -= 2.0 * .pi
        }

        while delta < -.pi {
            delta += 2.0 * .pi
        }

        return delta
    }

    private static func degrees(
        _ radians: Float
    ) -> Float {
        radians * 180.0 / .pi
    }

    private static func normalizeSafe(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(vector)

        guard length > 0.0001 else {
            return fallback
        }

        return vector / length
    }
}
