import Foundation
import RealityKit
import simd

enum PortalLocalHeadingResolver {
    enum Error: Swift.Error, LocalizedError {
        case degenerateDirection(label: String)

        var errorDescription: String? {
            switch self {
            case .degenerateDirection(let label):
                return "\(label) has no horizontal direction."
            }
        }
    }

    static func normalizedHorizontal(
        _ direction: SIMD3<Float>,
        label: String
    ) throws -> SIMD3<Float> {
        let horizontal = SIMD3<Float>(direction.x, 0, direction.z)
        let length = simd_length(horizontal)

        guard length.isFinite, length > 0.001 else {
            throw Error.degenerateDirection(label: label)
        }

        return horizontal / length
    }

    static func worldDirection(
        portalRoot: Entity,
        localDirection: SIMD3<Float>,
        label: String
    ) throws -> SIMD3<Float> {
        let worldOrigin = portalRoot.convert(position: .zero, to: nil)
        let worldTarget = portalRoot.convert(
            position: localDirection,
            to: nil
        )

        return try normalizedHorizontal(
            worldTarget - worldOrigin,
            label: label
        )
    }

    static func worldYaw(
        portalRoot: Entity,
        localDirection: SIMD3<Float>,
        label: String
    ) throws -> simd_quatf {
        try worldYaw(
            forward: worldDirection(
                portalRoot: portalRoot,
                localDirection: localDirection,
                label: label
            ),
            label: label
        )
    }

    static func worldYaw(
        forward: SIMD3<Float>,
        label: String
    ) throws -> simd_quatf {
        let worldForward = try normalizedHorizontal(
            forward,
            label: label
        )
        return simd_normalize(
            simd_quatf(
                from: SIMD3<Float>(0, 0, -1),
                to: worldForward
            )
        )
    }

    static func signedYawRadians(
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) throws -> Float {
        let source = try normalizedHorizontal(
            from,
            label: "signedYaw.source"
        )
        let destination = try normalizedHorizontal(
            to,
            label: "signedYaw.destination"
        )
        let cross = simd_cross(source, destination)

        return atan2(
            simd_dot(SIMD3<Float>(0, 1, 0), cross),
            simd_dot(source, destination)
        )
    }

    static func angularErrorRadians(
        _ first: SIMD3<Float>,
        _ second: SIMD3<Float>
    ) throws -> Float {
        let a = try normalizedHorizontal(
            first,
            label: "angularError.first"
        )
        let b = try normalizedHorizontal(
            second,
            label: "angularError.second"
        )

        return acos(max(-1, min(1, simd_dot(a, b))))
    }
}
