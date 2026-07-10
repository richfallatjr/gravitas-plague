import Foundation
import simd
@testable import Gravitas_Plague

enum TuringStoryPlacementTestSupport {
    static func wallCandidate(
        id: UUID = UUID(),
        center: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        right: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        width: Float = 4,
        height: Float = 2.6,
        stability: Float = 0.9
    ) -> WallCandidate {
        WallCandidate(
            id: id,
            anchorID: id,
            worldTransform: matrix_identity_float4x4,
            center: center,
            normal: normal,
            up: SIMD3<Float>(0, 1, 0),
            right: right,
            width: width,
            height: height,
            stabilityScore: stability,
            lastUpdated: .distantPast
        )
    }

    static func floorCandidate(
        id: UUID = UUID(),
        center: SIMD3<Float> = .zero,
        width: Float = 8,
        depth: Float = 8
    ) -> FloorCandidate {
        FloorCandidate(
            id: id,
            anchorID: id,
            worldTransform: matrix_identity_float4x4,
            center: center,
            normal: SIMD3<Float>(0, 1, 0),
            right: SIMD3<Float>(1, 0, 0),
            forward: SIMD3<Float>(0, 0, 1),
            width: width,
            depth: depth,
            semantic: .floor,
            stabilityScore: 0.95,
            lastUpdated: .distantPast
        )
    }

    static func canonicalWall(
        source: WallCandidate,
        sourceIDs: [UUID]? = nil
    ) -> TuringStoryCanonicalWall {
        TuringStoryCanonicalWall(
            representativeWallUUID: source.id,
            sourceWallUUIDs: sourceIDs ?? [source.id],
            center: source.center,
            right: source.right,
            up: source.up,
            normal: source.normal,
            width: source.width,
            height: source.height,
            stability: source.stabilityScore,
            representativeCenterSnapshot: source.center,
            representativeNormalSnapshot: source.normal
        )
    }

    static func exactPlacement(
        id: String,
        propID: TuringStoryPropID,
        wallID: String,
        wallUUID: UUID,
        localX: Float,
        width: Float = 0.8,
        minY: Float = 0,
        maxY: Float = 1,
        quality: Float = 0.8
    ) -> TuringStoryExactPlacement {
        let rect = TuringStorySemanticRect(
            minX: localX - width * 0.5,
            minY: minY,
            maxX: localX + width * 0.5,
            maxY: maxY
        )
        return TuringStoryExactPlacement(
            placementID: id,
            propID: propID,
            wallUUID: wallUUID,
            wallID: wallID,
            localX: localX,
            localY: (minY + maxY) * 0.5,
            worldBottomY: minY,
            worldTopY: maxY,
            reservationWidth: width,
            reservationHeight: maxY - minY,
            visualWidth: width,
            visualHeight: maxY - minY,
            depthOffset: 0.018,
            floorWorldY: 0,
            floorFrontageScore: quality,
            floorEvidenceKnown: true,
            wallCenterScore: quality,
            cornerClearanceScore: quality,
            wallStabilityScore: 0.9,
            deterministicQuality: quality,
            semanticRect: rect,
            runtimeLocalX: localX,
            runtimeLocalY: (minY + maxY) * 0.5,
            runtimeSemanticRect: rect,
            liveWallCenterSnapshot: .zero,
            liveWallNormalSnapshot: SIMD3<Float>(0, 0, 1)
        )
    }

    static func catalog(
        _ placements: [TuringStoryExactPlacement]
    ) -> TuringStoryExactPlacementCatalog {
        TuringStoryExactPlacementCatalog(
            placements: placements,
            placementByID: Dictionary(uniqueKeysWithValues: placements.map { ($0.placementID, $0) }),
            fixedOccupancy: []
        )
    }

    static func perimeter(
        wallID: String = "w0",
        wallUUID: UUID,
        width: Float = 4
    ) -> TuringStoryRoomPerimeter {
        let source = wallCandidate(id: wallUUID, width: width)
        let wall = canonicalWall(source: source)
        return TuringStoryRoomPerimeter(
            scanID: "scan-test",
            floorWorldY: 0,
            roomCenterXZ: SIMD2<Float>(0, 1),
            isClosed: false,
            wallsClockwise: [
                TuringStoryPerimeterWall(
                    wallID: wallID,
                    representativeWallUUID: wallUUID,
                    startXZ: SIMD2<Float>(-width * 0.5, 0),
                    endXZ: SIMD2<Float>(width * 0.5, 0),
                    heightMeters: 2.6,
                    stability: 0.9,
                    sourceCandidateCount: 1,
                    aggregateFloorFrontageScore: 1,
                    runtimeWall: wall
                )
            ],
            wallIDBySourceUUID: [wallUUID: wallID]
        )
    }
}
