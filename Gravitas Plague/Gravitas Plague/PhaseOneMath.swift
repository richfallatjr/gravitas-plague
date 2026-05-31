import Foundation
import simd

enum PhaseOneMath {
    static func normalizedOrFallback(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)

        guard lengthSquared > 0.000001 else {
            return fallback
        }

        return simd_normalize(vector)
    }

    static func horizontalDistance(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>
    ) -> Float {
        let delta = SIMD2<Float>(a.x - b.x, a.z - b.z)
        return simd_length(delta)
    }

    static func yawRadiansForNegativeZForward(
        worldForward: SIMD3<Float>
    ) -> Float {
        let horizontalForward = normalizedOrFallback(
            SIMD3<Float>(worldForward.x, 0, worldForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        return atan2(-horizontalForward.x, -horizontalForward.z)
    }

    static func normalizedAngleRadians(_ angle: Float) -> Float {
        var result = angle

        while result > Float.pi {
            result -= Float.pi * 2
        }

        while result < -Float.pi {
            result += Float.pi * 2
        }

        return result
    }
}
