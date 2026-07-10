import Foundation
import simd

struct TuringStoryExactPlacementGenerator: Sendable {
    private let horizontalSampleStep: Float = 0.10

    func generate(
        room: TuringStoryCleansedRoom,
        perimeter: TuringStoryRoomPerimeter,
        frontageEvaluator: TuringStoryFloorFrontageEvaluator
    ) throws -> TuringStoryExactPlacementCatalog {
        let fixed = canonicalOccupancy(room: room, perimeter: perimeter)
        var placements: [TuringStoryExactPlacement] = []
        for perimeterWall in perimeter.wallsClockwise {
            let wall = perimeterWall.runtimeWall
            guard let representative = room.rawWallByID[wall.representativeWallUUID] else {
                continue
            }
            let posterSize = WallPosterMetrics.posterSize(for: representative)
            let envelopes = TuringStoryPlanningEnvelope.all(posterSize: posterSize)
            for envelope in envelopes {
                let visualSize = visualSize(for: envelope.propID, posterSize: posterSize)
                let availableWidth = wall.width - envelope.wallMarginMeters * 2
                guard availableWidth >= envelope.minimumWidthMeters else { continue }
                let reservationWidth = min(
                    envelope.maximumWidthMeters,
                    min(envelope.preferredWidthMeters, availableWidth)
                )
                let reservationHeight = envelope.reservationHeightMeters
                let semanticWorldCenterY = room.floor.worldY +
                    (envelope.bottomAboveFloorMeters + envelope.topAboveFloorMeters) * 0.5
                guard abs(wall.up.y) > 0.05 else { continue }
                let semanticLocalY = (semanticWorldCenterY - wall.center.y) / wall.up.y
                let visualWorldCenterY = visualCenterWorldY(
                    propID: envelope.propID,
                    floorY: room.floor.worldY,
                    visualHeight: visualSize.y,
                    envelope: envelope
                )
                let visualLocalY = (visualWorldCenterY - wall.center.y) / wall.up.y
                guard verticalFitIsLegal(
                    propID: envelope.propID,
                    localY: semanticLocalY,
                    height: reservationHeight,
                    wall: wall
                ) else { continue }

                let maxX = wall.width * 0.5 - reservationWidth * 0.5 - envelope.wallMarginMeters
                guard maxX >= 0 else { continue }
                for localX in sampledCenters(maxX: maxX) {
                    let semanticRect = TuringStorySemanticRect(
                        minX: localX - reservationWidth * 0.5,
                        minY: semanticLocalY - reservationHeight * 0.5,
                        maxX: localX + reservationWidth * 0.5,
                        maxY: semanticLocalY + reservationHeight * 0.5
                    )
                    guard !fixed.contains(where: {
                        $0.wallID == perimeterWall.wallID && semanticRect.overlaps($0.paddedRect)
                    }) else { continue }

                    let frontage = frontageEvaluator.evaluate(
                        wall: wall,
                        localX: localX,
                        reservationWidth: reservationWidth,
                        frontageDepth: envelope.preferredFrontageDepthMeters,
                        roomCenterXZ: perimeter.roomCenterXZ,
                        floors: room.floor.sourceFloors
                    )
                    let wallCenterScore = max(0, 1 - abs(localX) / max(0.001, maxX))
                    let cornerClearance = min(
                        semanticRect.minX - (-wall.width * 0.5),
                        wall.width * 0.5 - semanticRect.maxX
                    )
                    let cornerClearanceScore = min(1, max(0, cornerClearance / 0.90))
                    let quality = deterministicQuality(
                        propID: envelope.propID,
                        floorFrontageScore: frontage.score,
                        wallCenterScore: wallCenterScore,
                        cornerClearanceScore: cornerClearanceScore,
                        wallStabilityScore: wall.stability
                    )
                    let runtime = runtimeProjection(
                        wall: wall,
                        representative: representative,
                        localX: localX,
                        visualLocalY: visualLocalY,
                        semanticLocalY: semanticLocalY,
                        reservationWidth: reservationWidth,
                        reservationHeight: reservationHeight
                    )
                    placements.append(
                        TuringStoryExactPlacement(
                            placementID: placementID(
                                propID: envelope.propID,
                                wallID: perimeterWall.wallID,
                                localX: localX
                            ),
                            propID: envelope.propID,
                            wallUUID: wall.representativeWallUUID,
                            wallID: perimeterWall.wallID,
                            localX: localX,
                            localY: visualLocalY,
                            worldBottomY: room.floor.worldY + envelope.bottomAboveFloorMeters,
                            worldTopY: room.floor.worldY + envelope.topAboveFloorMeters,
                            reservationWidth: reservationWidth,
                            reservationHeight: reservationHeight,
                            visualWidth: visualSize.x,
                            visualHeight: visualSize.y,
                            depthOffset: envelope.depthOffsetMeters,
                            floorWorldY: room.floor.worldY,
                            floorFrontageScore: frontage.score,
                            floorEvidenceKnown: !room.floor.sourceFloors.isEmpty,
                            wallCenterScore: wallCenterScore,
                            cornerClearanceScore: cornerClearanceScore,
                            wallStabilityScore: wall.stability,
                            deterministicQuality: quality,
                            semanticRect: semanticRect,
                            runtimeLocalX: runtime.localX,
                            runtimeLocalY: runtime.localY,
                            runtimeSemanticRect: runtime.semanticRect,
                            liveWallCenterSnapshot: wall.representativeCenterSnapshot,
                            liveWallNormalSnapshot: wall.representativeNormalSnapshot
                        )
                    )
                }
            }
        }
        let ordered = placements.sorted { $0.placementID < $1.placementID }
        let map = Dictionary(uniqueKeysWithValues: ordered.map { ($0.placementID, $0) })
        guard !ordered.filter({ $0.propID == .door }).isEmpty else {
            throw TuringStoryHotspotLayoutError.noLegalDoorPlacement
        }
        return TuringStoryExactPlacementCatalog(
            placements: ordered,
            placementByID: map,
            fixedOccupancy: fixed
        )
    }

    private func sampledCenters(maxX: Float) -> [Float] {
        guard maxX > 0.001 else { return [0] }
        var centimeters: Set<Int> = [
            0, Int((maxX * 100).rounded()), Int((-maxX * 100).rounded())
        ]
        var value = -maxX
        while value <= maxX {
            centimeters.insert(Int((value * 100).rounded()))
            value += horizontalSampleStep
        }
        return centimeters.sorted().map { Float($0) / 100 }
    }

    private func visualSize(
        for propID: TuringStoryPropID,
        posterSize: SIMD2<Float>
    ) -> SIMD2<Float> {
        switch propID {
        case .door:
            return SIMD2<Float>(
                TuringStoryDoorBundleTuning.defaultWidthMeters,
                TuringStoryDoorBundleTuning.defaultHeightMeters
            )
        case .window:
            return SIMD2<Float>(
                TuringStoryWindowBundleTuning.defaultWidthMeters,
                TuringStoryWindowBundleTuning.defaultHeightMeters
            )
        case .walkieShelf:
            return SIMD2<Float>(
                TuringStoryWalkieBundleTuning.defaultWidthMeters,
                TuringStoryWalkieBundleTuning.defaultHeightMeters
            )
        case .poster:
            return posterSize
        }
    }

    private func visualCenterWorldY(
        propID: TuringStoryPropID,
        floorY: Float,
        visualHeight: Float,
        envelope: TuringStoryPlanningEnvelope
    ) -> Float {
        switch propID {
        case .door:
            return floorY + visualHeight * 0.5
        case .window:
            return floorY + TuringStoryWindowBundleTuning.preferredBottomHeightMeters +
                visualHeight * 0.5
        case .walkieShelf:
            return floorY + TuringStoryWalkieBundleTuning.preferredCenterHeightMeters
        case .poster:
            return floorY + (envelope.bottomAboveFloorMeters + envelope.topAboveFloorMeters) * 0.5
        }
    }

    private func verticalFitIsLegal(
        propID: TuringStoryPropID,
        localY: Float,
        height: Float,
        wall: TuringStoryCanonicalWall
    ) -> Bool {
        if propID == .door { return true }
        let tolerance: Float = propID == .walkieShelf ? 0.08 : 0
        return localY - height * 0.5 >= -wall.height * 0.5 - tolerance &&
            localY + height * 0.5 <= wall.height * 0.5 + tolerance
    }

    private func deterministicQuality(
        propID: TuringStoryPropID,
        floorFrontageScore: Float,
        wallCenterScore: Float,
        cornerClearanceScore: Float,
        wallStabilityScore: Float
    ) -> Float {
        switch propID {
        case .door:
            return floorFrontageScore * 0.42 + wallCenterScore * 0.23 +
                cornerClearanceScore * 0.17 + wallStabilityScore * 0.18
        case .window:
            return floorFrontageScore * 0.18 + wallCenterScore * 0.32 +
                cornerClearanceScore * 0.24 + wallStabilityScore * 0.26
        case .walkieShelf:
            return floorFrontageScore * 0.16 + wallCenterScore * 0.34 +
                cornerClearanceScore * 0.24 + wallStabilityScore * 0.26
        case .poster:
            return wallCenterScore * 0.40 + cornerClearanceScore * 0.28 +
                wallStabilityScore * 0.32
        }
    }

    private func runtimeProjection(
        wall: TuringStoryCanonicalWall,
        representative: WallCandidate,
        localX: Float,
        visualLocalY: Float,
        semanticLocalY: Float,
        reservationWidth: Float,
        reservationHeight: Float
    ) -> (localX: Float, localY: Float, semanticRect: TuringStorySemanticRect) {
        let visualWorld = wall.center + wall.right * localX + wall.up * visualLocalY
        let visualDelta = visualWorld - representative.center
        let semanticCenter = wall.center + wall.right * localX + wall.up * semanticLocalY
        let halfRight = wall.right * (reservationWidth * 0.5)
        let halfUp = wall.up * (reservationHeight * 0.5)
        let corners: [SIMD3<Float>] = [
            semanticCenter - halfRight - halfUp,
            semanticCenter + halfRight - halfUp,
            semanticCenter - halfRight + halfUp,
            semanticCenter + halfRight + halfUp
        ]
        let projected = corners.map { point -> SIMD2<Float> in
            let delta = point - representative.center
            return SIMD2<Float>(
                simd_dot(delta, representative.right),
                simd_dot(delta, representative.up)
            )
        }
        return (
            simd_dot(visualDelta, representative.right),
            simd_dot(visualDelta, representative.up),
            TuringStorySemanticRect(
                minX: projected.map(\.x).min() ?? 0,
                minY: projected.map(\.y).min() ?? 0,
                maxX: projected.map(\.x).max() ?? 0,
                maxY: projected.map(\.y).max() ?? 0
            )
        )
    }

    private func placementID(
        propID: TuringStoryPropID,
        wallID: String,
        localX: Float
    ) -> String {
        let centimeters = Int((localX * 100).rounded())
        let x = centimeters < 0
            ? String(format: "-%03d", abs(centimeters))
            : String(format: "%03d", centimeters)
        return "\(propID.shortID):\(wallID):x-\(x)"
    }

    private func canonicalOccupancy(
        room: TuringStoryCleansedRoom,
        perimeter: TuringStoryRoomPerimeter
    ) -> [TuringStoryCanonicalOccupancy] {
        room.fixedOccupancy.compactMap { record in
            guard let wallID = perimeter.wallIDBySourceUUID[record.wallID],
                  let perimeterWall = perimeter.wallByID[wallID],
                  let source = room.rawWallByID[record.wallID] else {
                return nil
            }
            let wall = perimeterWall.runtimeWall
            let sourceCorners = [
                SIMD2<Float>(record.rect.minX, record.rect.minY),
                SIMD2<Float>(record.rect.maxX, record.rect.minY),
                SIMD2<Float>(record.rect.minX, record.rect.maxY),
                SIMD2<Float>(record.rect.maxX, record.rect.maxY)
            ].map { source.center + source.right * $0.x + source.up * $0.y }
            let projected = sourceCorners.map { point -> SIMD2<Float> in
                let delta = point - wall.center
                return SIMD2<Float>(simd_dot(delta, wall.right), simd_dot(delta, wall.up))
            }
            return TuringStoryCanonicalOccupancy(
                occupancyID: record.id,
                wallID: wallID,
                kind: record.kind,
                rect: TuringStorySemanticRect(
                    minX: projected.map(\.x).min() ?? 0,
                    minY: projected.map(\.y).min() ?? 0,
                    maxX: projected.map(\.x).max() ?? 0,
                    maxY: projected.map(\.y).max() ?? 0
                ),
                padding: record.padding
            )
        }
    }
}
