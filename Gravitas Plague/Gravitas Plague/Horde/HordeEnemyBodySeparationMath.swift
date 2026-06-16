import simd

enum HordeEnemyBodySeparationMath {
    struct MTV {
        /// Direction to move A away from B in XZ world.
        let axisXZ: SIMD2<Float>

        /// Penetration amount in meters.
        let depth: Float
    }

    static func minimumTranslationVector(
        _ a: HordeEnemyCollisionSnapshot,
        _ b: HordeEnemyCollisionSnapshot
    ) -> MTV? {
        guard a.minY <= b.maxY && a.maxY >= b.minY else {
            return nil
        }

        let axes = [
            a.rightXZ,
            a.forwardXZ,
            b.rightXZ,
            b.forwardXZ
        ]

        let centerDelta = SIMD2<Float>(
            a.centerWorld.x - b.centerWorld.x,
            a.centerWorld.z - b.centerWorld.z
        )

        var bestAxis = SIMD2<Float>(1, 0)
        var bestOverlap = Float.greatestFiniteMagnitude

        for rawAxis in axes {
            let axis = normalizeSeparationAxis(
                rawAxis,
                fallback: SIMD2<Float>(1, 0)
            )

            let distance = abs(
                simd_dot(centerDelta, axis)
            )

            let aRadius =
                abs(simd_dot(a.rightXZ, axis)) * a.halfWidth +
                abs(simd_dot(a.forwardXZ, axis)) * a.halfDepth

            let bRadius =
                abs(simd_dot(b.rightXZ, axis)) * b.halfWidth +
                abs(simd_dot(b.forwardXZ, axis)) * b.halfDepth

            let overlap = aRadius + bRadius - distance

            if overlap <= 0 {
                return nil
            }

            if overlap < bestOverlap {
                bestOverlap = overlap

                let directionSign: Float =
                    simd_dot(centerDelta, axis) >= 0 ? 1 : -1

                bestAxis = axis * directionSign
            }
        }

        return MTV(
            axisXZ: bestAxis,
            depth: bestOverlap
        )
    }
}

private func normalizeSeparationAxis(
    _ v: SIMD2<Float>,
    fallback: SIMD2<Float>
) -> SIMD2<Float> {
    let length = simd_length(v)

    guard length > 0.00001 else {
        return fallback
    }

    return v / length
}
