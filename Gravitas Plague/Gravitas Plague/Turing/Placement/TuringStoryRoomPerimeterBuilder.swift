import Foundation
import simd

struct TuringStoryRoomPerimeterBuilder: Sendable {
    private struct Draft {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        var wall: TuringStoryCanonicalWall
    }

    private let maximumEndpointGap: Float = 0.35
    private let maximumDirectionDeltaDegrees: Float = 8.0

    func build(
        room: TuringStoryCleansedRoom,
        frontageEvaluator: TuringStoryFloorFrontageEvaluator
    ) throws -> TuringStoryRoomPerimeter {
        guard !room.walls.isEmpty else { throw TuringStoryHotspotLayoutError.noPerimeter }
        let center = roomCenter(room)
        var drafts = room.walls.map { orientedDraft($0, roomCenter: center) }
        drafts.sort {
            angle($0, center: center) > angle($1, center: center)
        }
        drafts = mergeAdjacentCollinear(drafts)

        var sourceMap: [UUID: String] = [:]
        let walls = drafts.enumerated().map { index, draft in
            let wallID = "w\(index)"
            for sourceID in draft.wall.sourceWallUUIDs { sourceMap[sourceID] = wallID }
            let support = frontageEvaluator.evaluate(
                wall: draft.wall,
                localX: 0,
                reservationWidth: min(1.2, draft.wall.width),
                frontageDepth: 0.90,
                roomCenterXZ: center,
                floors: room.floor.sourceFloors
            ).score
            return TuringStoryPerimeterWall(
                wallID: wallID,
                representativeWallUUID: draft.wall.representativeWallUUID,
                startXZ: draft.start,
                endXZ: draft.end,
                heightMeters: draft.wall.height,
                stability: draft.wall.stability,
                sourceCandidateCount: draft.wall.sourceWallUUIDs.count,
                aggregateFloorFrontageScore: support,
                runtimeWall: draft.wall
            )
        }
        guard !walls.isEmpty else { throw TuringStoryHotspotLayoutError.noPerimeter }
        let isClosed = walls.indices.allSatisfy { index in
            let next = walls[(index + 1) % walls.count]
            return simd_length(walls[index].endXZ - next.startXZ) <= maximumEndpointGap
        }
        return TuringStoryRoomPerimeter(
            scanID: room.scanID,
            floorWorldY: room.floor.worldY,
            roomCenterXZ: center,
            isClosed: isClosed,
            wallsClockwise: walls,
            wallIDBySourceUUID: sourceMap
        )
    }

    private func roomCenter(_ room: TuringStoryCleansedRoom) -> SIMD2<Float> {
        let area = room.floor.sourceFloors.reduce(Float.zero) { $0 + $1.area }
        if area > 0.001 {
            return room.floor.sourceFloors.reduce(SIMD2<Float>.zero) { partial, floor in
                partial + SIMD2<Float>(floor.center.x, floor.center.z) * floor.area
            } / area
        }
        return room.walls.reduce(SIMD2<Float>.zero) { partial, wall in
            partial + SIMD2<Float>(wall.center.x, wall.center.z)
        } / Float(max(1, room.walls.count))
    }

    private func orientedDraft(
        _ original: TuringStoryCanonicalWall,
        roomCenter: SIMD2<Float>
    ) -> Draft {
        var wall = original
        let towardCenter = SIMD3<Float>(
            roomCenter.x - wall.center.x,
            0,
            roomCenter.y - wall.center.z
        )
        if simd_dot(wall.normal, towardCenter) < 0 {
            wall = TuringStoryCanonicalWall(
                representativeWallUUID: wall.representativeWallUUID,
                sourceWallUUIDs: wall.sourceWallUUIDs,
                center: wall.center,
                right: -wall.right,
                up: wall.up,
                normal: -wall.normal,
                width: wall.width,
                height: wall.height,
                stability: wall.stability,
                representativeCenterSnapshot: wall.representativeCenterSnapshot,
                representativeNormalSnapshot: wall.representativeNormalSnapshot
            )
        }
        let half = wall.right * (wall.width * 0.5)
        var start = SIMD2<Float>(wall.center.x - half.x, wall.center.z - half.z)
        var end = SIMD2<Float>(wall.center.x + half.x, wall.center.z + half.z)
        let radial = SIMD2<Float>(wall.center.x, wall.center.z) - roomCenter
        let clockwiseTangent = SIMD2<Float>(radial.y, -radial.x)
        if simd_dot(end - start, clockwiseTangent) < 0 { swap(&start, &end) }
        return Draft(start: start, end: end, wall: wall)
    }

    private func angle(_ draft: Draft, center: SIMD2<Float>) -> Float {
        let delta = (draft.start + draft.end) * 0.5 - center
        return atan2(delta.y, delta.x)
    }

    private func mergeAdjacentCollinear(_ input: [Draft]) -> [Draft] {
        guard input.count > 1 else { return input }
        var result: [Draft] = []
        for draft in input {
            guard var previous = result.last,
                  mayMerge(previous, draft) else {
                result.append(draft)
                continue
            }
            result.removeLast()
            let mergedSources = Array(
                Set(previous.wall.sourceWallUUIDs + draft.wall.sourceWallUUIDs)
            ).sorted { $0.uuidString < $1.uuidString }
            let representative = previous.wall.stability >= draft.wall.stability
                ? previous.wall : draft.wall
            let direction = turingStoryUnit(
                SIMD3<Float>(
                    draft.end.x - previous.start.x,
                    0,
                    draft.end.y - previous.start.y
                ),
                fallback: previous.wall.right
            )
            let width = simd_length(draft.end - previous.start)
            let midpoint = (previous.start + draft.end) * 0.5
            previous.end = draft.end
            previous.wall = TuringStoryCanonicalWall(
                representativeWallUUID: representative.representativeWallUUID,
                sourceWallUUIDs: mergedSources,
                center: SIMD3<Float>(midpoint.x, representative.center.y, midpoint.y),
                right: direction,
                up: representative.up,
                normal: representative.normal,
                width: width,
                height: max(previous.wall.height, draft.wall.height),
                stability: max(previous.wall.stability, draft.wall.stability),
                representativeCenterSnapshot: representative.representativeCenterSnapshot,
                representativeNormalSnapshot: representative.representativeNormalSnapshot
            )
            result.append(previous)
        }
        return result
    }

    private func mayMerge(_ lhs: Draft, _ rhs: Draft) -> Bool {
        guard simd_length(lhs.end - rhs.start) <= maximumEndpointGap else { return false }
        let lhsDirection = turingPerimeterUnit(lhs.end - lhs.start)
        let rhsDirection = turingPerimeterUnit(rhs.end - rhs.start)
        let dot = min(1, max(-1, simd_dot(lhsDirection, rhsDirection)))
        let angleDegrees = acos(dot) * 180 / .pi
        guard angleDegrees <= maximumDirectionDeltaDegrees else { return false }
        let normalDot = abs(simd_dot(lhs.wall.normal, rhs.wall.normal))
        return normalDot >= cos(maximumDirectionDeltaDegrees * .pi / 180)
    }
}

private func turingPerimeterUnit(_ value: SIMD2<Float>) -> SIMD2<Float> {
    let magnitude = simd_length(value)
    guard magnitude > 0.0001 else { return SIMD2<Float>(1, 0) }
    return value / magnitude
}
