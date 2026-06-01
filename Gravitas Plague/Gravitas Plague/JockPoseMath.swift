import Foundation
import RealityKit
import simd

enum JockPoseMath {
    static func radians(_ degrees: Float) -> Float {
        degrees * Float.pi / 180.0
    }

    static func quatFromEulerXYZDegrees(_ degrees: SIMD3<Float>) -> simd_quatf {
        let rx = simd_quatf(
            angle: radians(degrees.x),
            axis: SIMD3<Float>(1, 0, 0)
        )

        let ry = simd_quatf(
            angle: radians(degrees.y),
            axis: SIMD3<Float>(0, 1, 0)
        )

        let rz = simd_quatf(
            angle: radians(degrees.z),
            axis: SIMD3<Float>(0, 0, 1)
        )

        return rz * ry * rx
    }

    static func quatFromWXYZ(_ values: [Float]) -> simd_quatf {
        guard values.count >= 4 else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        return simd_quatf(
            ix: values[1],
            iy: values[2],
            iz: values[3],
            r: values[0]
        )
    }

    static func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        simd_slerp(a, b, t)
    }

    static func sampleVector3(keys: [JockAnimClip.Key], time: Double) -> SIMD3<Float> {
        let values = sampleValueArray(keys: keys, time: time, expectedCount: 3)

        return SIMD3<Float>(
            values[safe: 0] ?? 0,
            values[safe: 1] ?? 0,
            values[safe: 2] ?? 0
        )
    }

    static func sampleQuaternionWXYZ(keys: [JockAnimClip.Key], time: Double) -> simd_quatf {
        guard !keys.isEmpty else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        let sorted = keys.sorted { $0.t < $1.t }

        if time <= sorted[0].t {
            return quatFromWXYZ(sorted[0].value)
        }

        if time >= sorted[sorted.count - 1].t {
            return quatFromWXYZ(sorted[sorted.count - 1].value)
        }

        for index in 0..<(sorted.count - 1) {
            let lhs = sorted[index]
            let rhs = sorted[index + 1]

            if time >= lhs.t && time <= rhs.t {
                let span = max(rhs.t - lhs.t, 0.0001)
                let alpha = Float((time - lhs.t) / span)

                return slerp(
                    quatFromWXYZ(lhs.value),
                    quatFromWXYZ(rhs.value),
                    alpha
                )
            }
        }

        return quatFromWXYZ(sorted[0].value)
    }

    static func sampleEulerXYZDegreesAsQuaternion(
        keys: [JockAnimClip.Key],
        time: Double
    ) -> simd_quatf {
        quatFromEulerXYZDegrees(sampleVector3(keys: keys, time: time))
    }

    static func blendTransforms(
        from: [Transform],
        to: [Transform],
        alpha: Float
    ) -> [Transform] {
        let count = min(from.count, to.count)

        var result = from

        for index in 0..<count {
            result[index].translation = lerp(
                from[index].translation,
                to[index].translation,
                alpha
            )

            result[index].scale = lerp(
                from[index].scale,
                to[index].scale,
                alpha
            )

            result[index].rotation = slerp(
                from[index].rotation,
                to[index].rotation,
                alpha
            )
        }

        return result
    }

    private static func sampleValueArray(
        keys: [JockAnimClip.Key],
        time: Double,
        expectedCount: Int
    ) -> [Float] {
        guard !keys.isEmpty else {
            return Array(repeating: 0, count: expectedCount)
        }

        let sorted = keys.sorted { $0.t < $1.t }

        if time <= sorted[0].t {
            return padded(sorted[0].value, count: expectedCount)
        }

        if time >= sorted[sorted.count - 1].t {
            return padded(sorted[sorted.count - 1].value, count: expectedCount)
        }

        for index in 0..<(sorted.count - 1) {
            let lhs = sorted[index]
            let rhs = sorted[index + 1]

            if time >= lhs.t && time <= rhs.t {
                let span = max(rhs.t - lhs.t, 0.0001)
                let alpha = Float((time - lhs.t) / span)

                let lhsValues = padded(lhs.value, count: expectedCount)
                let rhsValues = padded(rhs.value, count: expectedCount)

                return zip(lhsValues, rhsValues).map { left, right in
                    left + (right - left) * alpha
                }
            }
        }

        return padded(sorted[0].value, count: expectedCount)
    }

    private static func padded(_ values: [Float], count: Int) -> [Float] {
        if values.count >= count {
            return Array(values.prefix(count))
        }

        return values + Array(repeating: 0, count: count - values.count)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
