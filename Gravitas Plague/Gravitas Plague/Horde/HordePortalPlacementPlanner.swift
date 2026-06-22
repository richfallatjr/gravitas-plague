import Foundation
import simd

struct HordePortalPlacementPlanInput: Sendable {
    let wave: Int
    let spawnIndex: Int
    let playerPosition: SIMD3<Float>
    let playerForward: SIMD3<Float>
    let walls: [WallCandidate]
    let floors: [FloorCandidate]
    let occupancyRecords: [WallPropOccupancyRecord]
    let existingCenters: [SIMD3<Float>]
    let reservedCenters: [SIMD3<Float>]
    let existingPortalBearings: [Float]
    let viewerY: Float
}

actor HordePortalPlacementPlannerEngine {
    func choosePlacement(
        input: HordePortalPlacementPlanInput
    ) -> HordePortalPlacementCandidate? {
        HordePortalPlacementPlanner.choosePlacement(
            input: input
        )
    }
}

enum HordePortalPlacementPlanner {
    static func choosePlacement(
        input: HordePortalPlacementPlanInput
    ) -> HordePortalPlacementCandidate? {
        _ = input.playerForward

        let walls = input.walls.filter {
            $0.isLargeEnoughForDefaultDoor
        }

        guard !walls.isEmpty else {
            return nil
        }

        var candidates: [HordePortalPlacementCandidate] = []

        for wall in walls {
            let floorRequest = RoomGeometryFloorSelectionRequest(
                floors: input.floors,
                viewerY: input.viewerY,
                wall: wall
            )

            guard RoomGeometrySelectionScorer.selectBestFloor(
                request: floorRequest
            ).floorID != nil else {
                print(
                    """
                    [HordePortalPlacement] wall skipped
                      wallID: \(wall.id)
                      reason: no_verified_floor_near_wall
                    """
                )
                continue
            }

            for slot in generateWallSlots(
                wall: wall
            ) {
                guard let placement = resolveFloorLockedPlacement(
                    slot,
                    wall: wall,
                    floors: input.floors,
                    viewerY: input.viewerY
                ) else {
                    print("[HordePortal] skipped portal placement: no verified floor")
                    continue
                }

                let rect = wallRect(
                    for: placement
                )
                let candidateRect = rect.expanded(
                    by: WallPosterPlacementTuning.portalCandidateExpansionMeters
                )

                if hasHardOverlap(
                    wallID: wall.id,
                    candidate: candidateRect,
                    candidateKind: .hordePortal,
                    records: input.occupancyRecords
                ) {
                    print(
                        """
                        [HordePortalPlacement] rejected candidate
                          wave: \(input.wave)
                          spawnIndex: \(input.spawnIndex)
                          reason: overlaps_wall_poster_or_existing_portal
                          wallID: \(wall.id)
                          localX: \(placement.localX)
                          localY: \(placement.localY)
                          rect: \(candidateRect)
                        """
                    )
                    continue
                }

                let center = worldCenter(
                    placement: placement,
                    wall: wall
                )
                let bearing = atan2(
                    center.x - input.playerPosition.x,
                    center.z - input.playerPosition.z
                )

                let nearestExisting = nearestDistance(
                    center,
                    to: input.existingCenters
                )
                let nearestRegisteredPortal = nearestOccupancyDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.hordePortal],
                    records: input.occupancyRecords
                )
                let posterDistance = nearestOccupancyDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.wallPoster],
                    records: input.occupancyRecords
                )
                let nearestPortalDistance = min(
                    nearestExisting,
                    nearestRegisteredPortal
                )
                let nearestReserved = nearestDistance(
                    center,
                    to: input.reservedCenters
                )
                let bearingGap = nearestExistingPortalBearingGap(
                    bearing,
                    existingBearings: input.existingPortalBearings
                )
                let spacingOK =
                    nearestPortalDistance >= HordePortalPlacementTuning.minSpacingMeters &&
                    nearestReserved >= HordePortalPlacementTuning.minSpacingMeters

                let spacingScore = min(
                    1,
                    min(
                        nearestPortalDistance,
                        nearestReserved
                    ) / HordePortalPlacementTuning.preferredSpacingMeters
                )
                let posterClearanceScore = min(
                    1,
                    posterDistance / 1.0
                )
                let angularScore = min(
                    1,
                    bearingGap / (.pi / 3)
                )

                let score =
                    spacingScore * 3.0 +
                    posterClearanceScore * 5.0 +
                    angularScore * 2.0 +
                    Float.random(in: 0...0.20)

                candidates.append(
                    HordePortalPlacementCandidate(
                        wall: wall,
                        placement: placement,
                        worldCenter: center,
                        bearingRadians: bearing,
                        nearestPortalDistance: nearestPortalDistance,
                        nearestReservedDistance: nearestReserved,
                        posterClearanceDistance: posterDistance,
                        nearestBearingGap: bearingGap,
                        spacingOK: spacingOK,
                        score: score
                    )
                )
            }
        }

        let valid = candidates.filter(\.spacingOK)

        return (valid.isEmpty ? candidates : valid)
            .max { lhs, rhs in
                lhs.score < rhs.score
            }
    }

    private static func resolveFloorLockedPlacement(
        _ placement: DoorPlacement,
        wall: WallCandidate,
        floors: [FloorCandidate],
        viewerY: Float
    ) -> DoorPlacement? {
        var resolved = placement

        if resolved.floorLocked {
            let floor =
                resolved.floorAnchorID.flatMap { floorID in
                    floors.first {
                        $0.id == floorID || $0.anchorID == floorID
                    }
                }
                ?? bestFloor(
                    floors: floors,
                    viewerY: viewerY,
                    wall: wall
                )

            guard let floor,
                  let localY = floorLocalY(
                    for: wall,
                    floor: floor,
                    doorHeight: resolved.height,
                    bottomClearance: resolved.bottomClearance
                  ) else {
                return nil
            }

            resolved.localY = localY
            resolved.floorAnchorID = floor.id
            resolved.floorWorldY = floor.worldY
        }

        return clampPlacement(
            resolved,
            on: wall
        )
    }

    private static func bestFloor(
        floors: [FloorCandidate],
        viewerY: Float,
        wall: WallCandidate
    ) -> FloorCandidate? {
        let result = RoomGeometrySelectionScorer.selectBestFloor(
            request: RoomGeometryFloorSelectionRequest(
                floors: floors,
                viewerY: viewerY,
                wall: wall
            )
        )

        return result.floorID.flatMap { floorID in
            floors.first {
                $0.id == floorID
            }
        }
    }

    private static func floorLocalY(
        for wall: WallCandidate,
        floor: FloorCandidate,
        doorHeight: Float,
        bottomClearance: Float
    ) -> Float? {
        let upY = wall.up.y

        guard abs(upY) > 0.05 else {
            return nil
        }

        return ((floor.worldY + bottomClearance) - wall.center.y) / upY
            + doorHeight * 0.5
    }

    private static func generateWallSlots(
        wall: WallCandidate
    ) -> [DoorPlacement] {
        let widths: [Float] = [0.82, 0.92, 1.05]
        let heights: [Float] = [1.90, 2.05, 2.18]
        var placements: [DoorPlacement] = []

        for width in widths {
            for height in heights {
                var base = DoorPlacement.defaultForWall(wall)
                base.floorLocked = true
                base.confirmed = true
                base.contentProviderID = HordeHellscapePortalContentProvider.providerID
                base.width = width
                base.height = height

                let maxX = max(
                    0,
                    wall.width * 0.5 - width * 0.5 - 0.10
                )

                let spacing = max(
                    HordePortalPlacementTuning.minSpacingMeters,
                    width + 0.20
                )

                guard maxX > 0.01 else {
                    placements.append(base)
                    continue
                }

                var x = -maxX
                while x <= maxX + 0.001 {
                    var placement = base
                    placement.localX = x
                    placements.append(placement)
                    x += spacing
                }

                if !placements.contains(where: { existing in
                    existing.wallID == base.wallID &&
                    abs(existing.localX) < 0.01 &&
                    abs(existing.width - base.width) < 0.001 &&
                    abs(existing.height - base.height) < 0.001
                }) {
                    var center = base
                    center.localX = 0
                    placements.append(center)
                }
            }
        }

        return placements
    }

    private static func worldCenter(
        placement: DoorPlacement,
        wall: WallCandidate
    ) -> SIMD3<Float> {
        wall.center +
            wall.right * placement.localX +
            wall.up * placement.localY +
            wall.normal * placement.depthOffset
    }

    private static func wallRect(
        for placement: DoorPlacement
    ) -> WallLocalRect {
        WallLocalRect(
            minX: placement.localX - placement.width * 0.5,
            minY: placement.localY - placement.height * 0.5,
            maxX: placement.localX + placement.width * 0.5,
            maxY: placement.localY + placement.height * 0.5
        )
    }

    private static func clampPlacement(
        _ placement: DoorPlacement,
        on wall: WallCandidate
    ) -> DoorPlacement {
        var p = placement

        let overhang: Float = 0.075
        let maxX = max(
            0,
            wall.width * 0.5 - placement.width * 0.5 + overhang
        )

        p.localX = min(max(p.localX, -maxX), maxX)

        if !p.floorLocked {
            let maxY = max(
                0,
                wall.height * 0.5 - placement.height * 0.5 + overhang
            )

            p.localY = min(max(p.localY, -maxY), maxY)
        }

        p.depthOffset = max(0.005, min(0.02, p.depthOffset))

        return p
    }

    private static func hasHardOverlap(
        wallID: UUID,
        candidate: WallLocalRect,
        candidateKind: WallPropOccupancyKind,
        records: [WallPropOccupancyRecord]
    ) -> Bool {
        for record in records where record.wallID == wallID {
            let occupied = record.paddedRect

            guard candidate.overlaps(occupied) else {
                continue
            }

            if candidateKind == .hordePortal,
               record.kind == .wallPoster {
                print(
                    """
                    [WallOccupancy] HARD REJECT portal overlaps poster
                      candidateKind: \(candidateKind.rawValue)
                      recordKind: \(record.kind.rawValue)
                      recordLabel: \(record.label)
                      candidate: \(candidate)
                      occupied: \(occupied)
                    """
                )
                return true
            }

            if candidateKind == .hordePortal,
               record.kind == .hordePortal {
                print(
                    """
                    [WallOccupancy] HARD REJECT portal overlaps portal
                      recordLabel: \(record.label)
                      candidate: \(candidate)
                      occupied: \(occupied)
                    """
                )
                return true
            }

            if candidateKind == .wallPoster,
               record.kind == .hordePortal {
                return true
            }
        }

        return false
    }

    private static func nearestOccupancyDistance(
        wallID: UUID,
        candidate: WallLocalRect,
        kinds: Set<WallPropOccupancyKind>,
        records: [WallPropOccupancyRecord]
    ) -> Float {
        let distances = records
            .filter {
                $0.wallID == wallID && kinds.contains($0.kind)
            }
            .map {
                candidate.distanceTo($0.paddedRect)
            }

        return distances.min() ?? Float.greatestFiniteMagnitude
    }

    private static func nearestDistance(
        _ point: SIMD3<Float>,
        to points: [SIMD3<Float>]
    ) -> Float {
        guard !points.isEmpty else {
            return Float.greatestFiniteMagnitude
        }

        return points.map {
            simd_length($0 - point)
        }.min() ?? Float.greatestFiniteMagnitude
    }

    private static func nearestExistingPortalBearingGap(
        _ bearing: Float,
        existingBearings: [Float]
    ) -> Float {
        guard !existingBearings.isEmpty else {
            return .pi
        }

        return existingBearings.map {
            abs(
                shortestAngleDelta(
                    from: $0,
                    to: bearing
                )
            )
        }.min() ?? .pi
    }

    private static func shortestAngleDelta(
        from a: Float,
        to b: Float
    ) -> Float {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
