import Foundation
import simd

nonisolated struct Chapter03CircularPortalGeometry: Sendable, Equatable {
    static let segmentCount = 128

    let diameterMeters: Float
    let radiusMeters: Float
    /// Closed loop without a repeated final point.
    let boundaryPoints: [SIMD3<Float>]
    let discPositions: [SIMD3<Float>]
    let triangleIndices: [UInt32]

    static func make(diameterMeters: Float) throws -> Self {
        guard diameterMeters.isFinite, diameterMeters > 0 else {
            throw Chapter03Error.definitionInvalid("Portal diameter is invalid.")
        }
        let radius = diameterMeters * 0.5
        var boundary: [SIMD3<Float>] = []
        boundary.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let angle = 2 * Float.pi * Float(index) / Float(segmentCount)
            boundary.append(SIMD3<Float>(
                radius * cos(angle),
                radius * sin(angle),
                PortalFXDefaults.perimeterSurfaceOffsetMeters
            ))
        }
        var disc = [SIMD3<Float>(0, 0, 0)]
        disc.append(contentsOf: boundary.map { SIMD3<Float>($0.x, $0.y, 0) })
        var indices: [UInt32] = []
        indices.reserveCapacity(segmentCount * 3)
        for index in 0..<segmentCount {
            let next = (index + 1) % segmentCount
            indices.append(contentsOf: [0, UInt32(index + 1), UInt32(next + 1)])
        }
        return Self(
            diameterMeters: diameterMeters,
            radiusMeters: radius,
            boundaryPoints: boundary,
            discPositions: disc,
            triangleIndices: indices
        )
    }
}
