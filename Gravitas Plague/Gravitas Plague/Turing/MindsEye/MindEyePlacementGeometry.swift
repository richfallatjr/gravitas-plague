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
    let iconRelativePlacement: MindEyeIconRelativePlacement?
}

nonisolated struct MindEyeIconRelativePlacement: Sendable, Equatable {
    /// The center of the icon's top edge in presentation-root coordinates.
    let iconTopCenter: SIMD3<Float>
    /// Clear space from the icon's top edge to the card's bottom edge.
    let bottomEdgeClearanceMeters: Float
    /// Positive Z moves the card outward from the prop and toward the viewer.
    let forwardOffsetMeters: Float
}

nonisolated enum MindEyeIconPlacementDefaults {
    /// Keep wall-shelf cards two inches above the shared action icon.
    static let shelfBottomEdgeClearanceMeters: Float = 0.0508
    /// Preserve the approved rolling-bench bottom-edge height (2.5 inches).
    static let rollingBenchBottomEdgeClearanceMeters: Float = 0.0635
    /// Midpoint of the requested 1–2 inch walkie depth range.
    static let walkieForwardOffsetMeters: Float = 0.0381
    /// Midpoint of the requested 3–5 inch rolling-bench depth range.
    static let rollingBenchForwardOffsetMeters: Float = 0.1016
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
        cardWidthMeters: 0.84,
        cardHeightMeters: 0.4725,
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
