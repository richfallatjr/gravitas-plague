import Foundation
import simd

nonisolated struct MindEyeLocalBounds: Sendable, Equatable {
    let min: SIMD3<Float>
    let max: SIMD3<Float>

    var center: SIMD3<Float> { (min + max) * 0.5 }
    var size: SIMD3<Float> { max - min }
    var isFinite: Bool {
        min.x.isFinite && min.y.isFinite && min.z.isFinite &&
            max.x.isFinite && max.y.isFinite && max.z.isFinite
    }
    var isOrdered: Bool {
        max.x >= min.x && max.y >= min.y && max.z >= min.z
    }
    var hasUsefulPlanarExtent: Bool {
        size.x > 0.0001 && size.y > 0.0001
    }
    var isUsable: Bool { isFinite && isOrdered && hasUsefulPlanarExtent }

    func union(_ other: MindEyeLocalBounds) -> MindEyeLocalBounds {
        MindEyeLocalBounds(
            min: simd_min(min, other.min),
            max: simd_max(max, other.max)
        )
    }
}

nonisolated struct MindEyePlacementGeometry: Sendable, Equatable {
    let providerID: String
    let revision: UInt64
    let centeringBounds: MindEyeLocalBounds?
    let obstructionBounds: MindEyeLocalBounds?
    let fallbackCenter: SIMD3<Float>
}

nonisolated struct MindEyeResolvedPlacement: Sendable, Equatable {
    let providerID: String
    let providerRevision: UInt64
    let localPosition: SIMD3<Float>
    let usedFallbackCenter: Bool
    let verticalClampApplied: Bool
    let forwardClampApplied: Bool
}

nonisolated extension MindEyePlacementTuning {
    static let phaseThreeDefault = MindEyePlacementTuning(
        cardWidthMeters: 0.56,
        cardHeightMeters: 0.315,
        verticalLiftMeters: 0.10,
        forwardOffsetMeters: 0.0381,
        shelfClearanceMeters: 0.0127
    )
}

nonisolated enum MindEyeFiniteVector {
    static func validates(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
