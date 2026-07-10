import Foundation
import simd

struct TuringStoryFloorFrontageEvidence: Sendable, Hashable {
    let supportCoverage: Float
    let knownObstaclePenalty: Float
    let obstacleEvidenceKnown: Bool

    var score: Float {
        min(1, max(0, supportCoverage - knownObstaclePenalty))
    }
}

struct TuringStoryFloorFrontageEvaluator: Sendable {
    func evaluate(
        wall: TuringStoryCanonicalWall,
        localX: Float,
        reservationWidth: Float,
        frontageDepth: Float,
        roomCenterXZ: SIMD2<Float>,
        floors: [FloorCandidate]
    ) -> TuringStoryFloorFrontageEvidence {
        guard frontageDepth > 0.001, !floors.isEmpty else {
            return TuringStoryFloorFrontageEvidence(
                supportCoverage: frontageDepth <= 0.001 ? 1 : 0,
                knownObstaclePenalty: 0,
                obstacleEvidenceKnown: false
            )
        }
        let wallPoint = wall.center + wall.right * localX
        let wallXZ = SIMD2<Float>(wallPoint.x, wallPoint.z)
        let inward = unit2(roomCenterXZ - wallXZ)
        let rightXZ = unit2(SIMD2<Float>(wall.right.x, wall.right.z))
        var supported = 0
        let acrossSamples = 7
        let depthSamples = 5
        let total = acrossSamples * depthSamples
        for across in 0..<acrossSamples {
            let acrossU = Float(across) / Float(acrossSamples - 1) - 0.5
            for depth in 0..<depthSamples {
                let depthU = (Float(depth) + 0.5) / Float(depthSamples)
                let point = wallXZ +
                    rightXZ * (acrossU * reservationWidth) +
                    inward * (depthU * frontageDepth)
                if floors.contains(where: { contains(point, floor: $0) }) {
                    supported += 1
                }
            }
        }
        return TuringStoryFloorFrontageEvidence(
            supportCoverage: Float(supported) / Float(total),
            knownObstaclePenalty: 0,
            obstacleEvidenceKnown: false
        )
    }

    private func contains(
        _ point: SIMD2<Float>,
        floor: FloorCandidate
    ) -> Bool {
        let delta = SIMD3<Float>(
            point.x - floor.center.x,
            0,
            point.y - floor.center.z
        )
        let right = turingStoryUnit(floor.right, fallback: SIMD3<Float>(1, 0, 0))
        let forward = turingStoryUnit(floor.forward, fallback: SIMD3<Float>(0, 0, -1))
        return abs(simd_dot(delta, right)) <= floor.width * 0.5 &&
            abs(simd_dot(delta, forward)) <= floor.depth * 0.5
    }

    private func unit2(_ value: SIMD2<Float>) -> SIMD2<Float> {
        let magnitude = simd_length(value)
        guard magnitude > 0.0001 else { return SIMD2<Float>(0, 1) }
        return value / magnitude
    }
}
