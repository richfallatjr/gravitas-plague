import Foundation
import simd

struct RoomGeometryWallSelectionRequest: Sendable {
    let walls: [WallCandidate]
    let playerPosition: SIMD3<Float>
    let playerForward: SIMD3<Float>
}

struct RoomGeometryWallSelectionResult: Sendable {
    let wallID: UUID?
    let candidateCount: Int
    let selectedScore: Float?
}

struct RoomGeometryFloorSelectionRequest: Sendable {
    let floors: [FloorCandidate]
    let viewerY: Float
    let wall: WallCandidate?
}

struct RoomGeometryFloorSelectionResult: Sendable {
    let floorID: UUID?
    let candidateCount: Int
}

actor RoomGeometrySelectionEngine {
    func selectBestWall(
        request: RoomGeometryWallSelectionRequest
    ) -> RoomGeometryWallSelectionResult {
        RoomGeometrySelectionScorer.selectBestWall(
            request: request
        )
    }

    func selectBestFloor(
        request: RoomGeometryFloorSelectionRequest
    ) -> RoomGeometryFloorSelectionResult {
        RoomGeometrySelectionScorer.selectBestFloor(
            request: request
        )
    }
}

enum RoomGeometrySelectionScorer {
    static func selectBestWall(
        request: RoomGeometryWallSelectionRequest
    ) -> RoomGeometryWallSelectionResult {
        let candidates = request.walls.filter {
            $0.isLargeEnoughForDefaultDoor && $0.stabilityScore >= 0.35
        }

        guard !candidates.isEmpty else {
            return RoomGeometryWallSelectionResult(
                wallID: nil,
                candidateCount: 0,
                selectedScore: nil
            )
        }

        let playerForward = normalizeSafe(
            request.playerForward,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let scored = candidates.map { wall -> (WallCandidate, Float) in
            let toWall = normalizeSafe(
                wall.center - request.playerPosition,
                fallback: SIMD3<Float>(0, 0, -1)
            )

            let facesPlayer = max(
                0,
                simd_dot(wall.normal, -toWall)
            )

            let inFront = max(
                0,
                simd_dot(playerForward, toWall)
            )

            let distance = simd_length(
                wall.center - request.playerPosition
            )
            let distanceScore = max(
                0,
                1.0 - abs(distance - 2.0) / 4.0
            )

            let areaScore = min(
                1.0,
                (wall.width * wall.height) / 4.0
            )

            let score =
                facesPlayer * 2.0 +
                inFront * 1.25 +
                distanceScore * 0.75 +
                areaScore +
                wall.stabilityScore

            return (wall, score)
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }) else {
            return RoomGeometryWallSelectionResult(
                wallID: nil,
                candidateCount: candidates.count,
                selectedScore: nil
            )
        }

        return RoomGeometryWallSelectionResult(
            wallID: best.0.id,
            candidateCount: candidates.count,
            selectedScore: best.1
        )
    }

    static func selectBestFloor(
        request: RoomGeometryFloorSelectionRequest
    ) -> RoomGeometryFloorSelectionResult {
        let candidates = request.floors.filter { floor in
            guard floor.isUsableFloor else {
                return false
            }

            guard floor.worldY < request.viewerY - 0.85 else {
                return false
            }

            if let wall = request.wall {
                guard floor.worldY < wall.center.y - 0.35 else {
                    return false
                }
            }

            return true
        }

        guard !candidates.isEmpty else {
            return RoomGeometryFloorSelectionResult(
                floorID: nil,
                candidateCount: 0
            )
        }

        let sorted = candidates.sorted { lhs, rhs in
            if let wall = request.wall {
                let lhsDistance = simd_length(lhs.center - wall.center)
                let rhsDistance = simd_length(rhs.center - wall.center)

                if abs(lhsDistance - rhsDistance) > 0.3 {
                    return lhsDistance < rhsDistance
                }
            }

            if abs(lhs.area - rhs.area) > 0.5 {
                return lhs.area > rhs.area
            }

            if abs(lhs.stabilityScore - rhs.stabilityScore) > 0.1 {
                return lhs.stabilityScore > rhs.stabilityScore
            }

            return lhs.worldY < rhs.worldY
        }

        return RoomGeometryFloorSelectionResult(
            floorID: sorted[0].id,
            candidateCount: candidates.count
        )
    }
}

private func normalizeSafe(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(v)
    guard length > 0.00001 else {
        return fallback
    }
    return v / length
}
