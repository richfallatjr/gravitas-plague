import Foundation
import simd

struct TuringStoryExactPlacement: Sendable, Hashable {
    let placementID: String
    let propID: TuringStoryPropID
    let wallUUID: UUID
    let wallID: String
    let localX: Float
    let localY: Float
    let worldBottomY: Float
    let worldTopY: Float
    let reservationWidth: Float
    let reservationHeight: Float
    let visualWidth: Float
    let visualHeight: Float
    let depthOffset: Float
    let floorWorldY: Float
    let floorFrontageScore: Float
    let floorEvidenceKnown: Bool
    let wallCenterScore: Float
    let cornerClearanceScore: Float
    let wallStabilityScore: Float
    let deterministicQuality: Float
    let semanticRect: TuringStorySemanticRect
    let runtimeLocalX: Float
    let runtimeLocalY: Float
    let runtimeSemanticRect: TuringStorySemanticRect
    let liveWallCenterSnapshot: SIMD3<Float>
    let liveWallNormalSnapshot: SIMD3<Float>
}

struct TuringStoryCanonicalOccupancy: Sendable, Hashable {
    let occupancyID: UUID
    let wallID: String
    let kind: WallPropOccupancyKind
    let rect: TuringStorySemanticRect
    let padding: Float

    var paddedRect: TuringStorySemanticRect {
        TuringStorySemanticRect(
            minX: rect.minX - padding,
            minY: rect.minY - padding,
            maxX: rect.maxX + padding,
            maxY: rect.maxY + padding
        )
    }
}

struct TuringStoryExactPlacementCatalog: Sendable {
    let placements: [TuringStoryExactPlacement]
    let placementByID: [String: TuringStoryExactPlacement]
    let fixedOccupancy: [TuringStoryCanonicalOccupancy]

    func placements(for propID: TuringStoryPropID) -> [TuringStoryExactPlacement] {
        placements.filter { $0.propID == propID }
    }
}
