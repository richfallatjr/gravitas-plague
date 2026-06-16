import simd

enum HordeEnemyCollisionMath {
    static func boxesIntersect(
        _ a: HordeEnemyCollisionSnapshot,
        _ b: HordeEnemyCollisionSnapshot
    ) -> Bool {
        guard yRangesOverlap(a, b) else {
            return false
        }

        return obb2DIntersects(a, b)
    }

    static func shouldAStopBehindB(
        a: HordeEnemyCollisionSnapshot,
        b: HordeEnemyCollisionSnapshot,
        tieEpsilon: Float
    ) -> Bool {
        let delta = a.distanceToHeadsetXZ - b.distanceToHeadsetXZ

        if delta > tieEpsilon {
            return true
        }

        if abs(delta) <= tieEpsilon {
            return a.spawnIndex > b.spawnIndex
        }

        return false
    }

    private static func yRangesOverlap(
        _ a: HordeEnemyCollisionSnapshot,
        _ b: HordeEnemyCollisionSnapshot
    ) -> Bool {
        a.minY <= b.maxY && a.maxY >= b.minY
    }

    private static func obb2DIntersects(
        _ a: HordeEnemyCollisionSnapshot,
        _ b: HordeEnemyCollisionSnapshot
    ) -> Bool {
        let axes = [
            a.rightXZ,
            a.forwardXZ,
            b.rightXZ,
            b.forwardXZ
        ]

        let centerDelta = SIMD2<Float>(
            b.centerWorld.x - a.centerWorld.x,
            b.centerWorld.z - a.centerWorld.z
        )

        for axis in axes {
            let n = normalizeSafe2(
                axis,
                fallback: SIMD2<Float>(1, 0)
            )

            let distance = abs(
                simd_dot(centerDelta, n)
            )

            let aRadius =
                abs(simd_dot(a.rightXZ, n)) * a.halfWidth +
                abs(simd_dot(a.forwardXZ, n)) * a.halfDepth

            let bRadius =
                abs(simd_dot(b.rightXZ, n)) * b.halfWidth +
                abs(simd_dot(b.forwardXZ, n)) * b.halfDepth

            if distance > aRadius + bRadius {
                return false
            }
        }

        return true
    }
}
