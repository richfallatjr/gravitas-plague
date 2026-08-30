import Foundation
import simd

nonisolated enum MindEyeProjectionCameraMath {
    static let version = "mind-eye-projection-camera-v1"
    static let cubeFramingVersion = "mind-eye-projection-camera-cube-v1"

    struct Fit: Sendable, Equatable {
        let subjectFromCamera: simd_float4x4
        let clipFromCamera: simd_float4x4
        let clipFromSubject: simd_float4x4
        let targetCenter: SIMD3<Float>
        let targetMinimum: SIMD3<Float>
        let targetMaximum: SIMD3<Float>
    }

    static func fit(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        forwardAxis: SIMD3<Float>,
        localOffset: SIMD3<Float>,
        verticalFOVDegrees: Float = 30,
        near: Float = 0.02,
        far: Float = 20,
        padding: Float = 1.12
    ) throws -> Fit {
        let center = (minimum + maximum) * 0.5 + localOffset
        let extents = maximum - minimum
        guard extents.x > 0, extents.y > 0, extents.z > 0,
              verticalFOVDegrees > 0,
              near > 0, far > near, padding >= 1 else {
            throw MindEyeProjectionError.invalidCameraDescriptor
        }
        let normalizedForward = simd_normalize(forwardAxis)
        guard normalizedForward.x.isFinite, simd_length_squared(normalizedForward) > 0.99 else {
            throw MindEyeProjectionError.invalidCameraDescriptor
        }
        let halfFOV = verticalFOVDegrees * .pi / 360
        let distance = max(extents.x, extents.y) * 0.5 * padding / tan(halfFOV)
        let position = center - normalizedForward * distance
        let subjectFromCamera = lookAtCameraTransform(position: position, target: center)
        let clipFromCamera = perspective(
            verticalFOVRadians: verticalFOVDegrees * .pi / 180,
            aspect: 1,
            near: near,
            far: far
        )
        let cameraFromSubject = subjectFromCamera.inverse
        let clipFromSubject = clipFromCamera * cameraFromSubject
        guard subjectFromCamera.determinant.isFinite,
              abs(subjectFromCamera.determinant) > 0.000_001 else {
            throw MindEyeProjectionError.nonfiniteCameraDescriptor
        }
        return Fit(
            subjectFromCamera: subjectFromCamera,
            clipFromCamera: clipFromCamera,
            clipFromSubject: clipFromSubject,
            targetCenter: center,
            targetMinimum: minimum,
            targetMaximum: maximum
        )
    }

    static func fit(
        authoringControl control:
            MindEyeProjectionTargetDescriptor.AuthoringFramingControl,
        verticalFOVDegrees: Float = 30,
        near: Float = 0.02,
        far: Float = 20,
        padding: Float = 1.12
    ) throws -> Fit {
        try control.validate()
        let center = SIMD3<Float>(
            control.centerSubjectMeters[0],
            control.centerSubjectMeters[1],
            control.centerSubjectMeters[2]
        )
        let right = simd_normalize(SIMD3<Float>(
            control.rightAxisSubject[0],
            control.rightAxisSubject[1],
            control.rightAxisSubject[2]
        ))
        let up = simd_normalize(SIMD3<Float>(
            control.upAxisSubject[0],
            control.upAxisSubject[1],
            control.upAxisSubject[2]
        ))
        let forward = simd_normalize(SIMD3<Float>(
            control.forwardAxisSubject[0],
            control.forwardAxisSubject[1],
            control.forwardAxisSubject[2]
        ))
        let halfExtents = SIMD3<Float>(
            control.halfExtentsMeters[0],
            control.halfExtentsMeters[1],
            control.halfExtentsMeters[2]
        )
        guard verticalFOVDegrees > 0,
              near > 0,
              far > near,
              padding >= 1,
              simd_dot(simd_cross(forward, up), right) > 0.999 else {
            throw MindEyeProjectionError.invalidCameraDescriptor
        }
        let halfFOV = verticalFOVDegrees * .pi / 360
        let distance = halfExtents.z +
            max(halfExtents.x, halfExtents.y) * padding / tan(halfFOV)
        let position = center - forward * distance
        let subjectFromCamera = simd_float4x4(
            SIMD4(right, 0),
            SIMD4(up, 0),
            SIMD4(-forward, 0),
            SIMD4(position, 1)
        )
        let clipFromCamera = perspective(
            verticalFOVRadians: verticalFOVDegrees * .pi / 180,
            aspect: 1,
            near: near,
            far: far
        )
        let clipFromSubject = clipFromCamera * subjectFromCamera.inverse
        var corners: [SIMD3<Float>] = []
        for x in [-halfExtents.x, halfExtents.x] {
            for y in [-halfExtents.y, halfExtents.y] {
                for z in [-halfExtents.z, halfExtents.z] {
                    corners.append(center + right * x + up * y + forward * z)
                }
            }
        }
        let minimum = corners.reduce(
            SIMD3<Float>(repeating: .greatestFiniteMagnitude),
            { simd_min($0, $1) }
        )
        let maximum = corners.reduce(
            SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude),
            { simd_max($0, $1) }
        )
        return Fit(
            subjectFromCamera: subjectFromCamera,
            clipFromCamera: clipFromCamera,
            clipFromSubject: clipFromSubject,
            targetCenter: center,
            targetMinimum: minimum,
            targetMaximum: maximum
        )
    }

    static func projectorUV(subjectPosition: SIMD3<Float>, clipFromSubject: simd_float4x4) -> SIMD3<Float>? {
        let clip = clipFromSubject * SIMD4(subjectPosition, 1)
        guard clip.w > 0, clip.w.isFinite else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite,
              (0...1).contains(ndc.z) else { return nil }
        return SIMD3(ndc.x * 0.5 + 0.5, 1 - (ndc.y * 0.5 + 0.5), ndc.z)
    }

    private static func lookAtCameraTransform(position: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        return simd_float4x4(
            SIMD4(right, 0),
            SIMD4(up, 0),
            SIMD4(-forward, 0),
            SIMD4(position, 1)
        )
    }

    private static func perspective(
        verticalFOVRadians: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(verticalFOVRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        )
    }
}
