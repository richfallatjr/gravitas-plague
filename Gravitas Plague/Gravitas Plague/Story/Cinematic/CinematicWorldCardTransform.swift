import simd

enum CinematicWorldCardTransform {
    static let distanceMeters: Float = 1.5
    static let worldYLiftMeters: Float = 0.6096
    static let titleWorldYLiftMeters: Float = -0.1524
    static let xTiltDegrees: Float = 20

    static func worldTransform(
        originFromDevice: simd_float4x4,
        verticalLiftMeters: Float = worldYLiftMeters,
        xRotationDegrees: Float = xTiltDegrees
    ) -> simd_float4x4 {
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4<Float>(
            0,
            0,
            -distanceMeters,
            1
        )

        let tilt = simd_float4x4(
            simd_quatf(
                angle: xRotationDegrees * .pi / 180,
                axis: SIMD3<Float>(1, 0, 0)
            )
        )

        var result = originFromDevice * translation * tilt
        result.columns.3.y += verticalLiftMeters
        return result
    }
}
