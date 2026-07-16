import Foundation
import simd

struct TuringStoryEstablishedLayoutFingerprint: Equatable {
    let doorWorldTransform: simd_float4x4
    let windowWorldTransform: simd_float4x4
    let walkieShelfWorldTransform: simd_float4x4
    let rollingBenchWorldTransform: simd_float4x4
    let posterWorldTransform: simd_float4x4
    let canonicalWallIDs: [UUID]
    let occupancyIDs: [UUID]

    static func == (lhs: Self, rhs: Self) -> Bool {
        matricesApproximatelyEqual(lhs.doorWorldTransform, rhs.doorWorldTransform) &&
            matricesApproximatelyEqual(lhs.windowWorldTransform, rhs.windowWorldTransform) &&
            matricesApproximatelyEqual(lhs.walkieShelfWorldTransform, rhs.walkieShelfWorldTransform) &&
            matricesApproximatelyEqual(lhs.rollingBenchWorldTransform, rhs.rollingBenchWorldTransform) &&
            matricesApproximatelyEqual(lhs.posterWorldTransform, rhs.posterWorldTransform) &&
            lhs.canonicalWallIDs == rhs.canonicalWallIDs &&
            lhs.occupancyIDs == rhs.occupancyIDs
    }

    private static func matricesApproximatelyEqual(
        _ lhs: simd_float4x4,
        _ rhs: simd_float4x4,
        tolerance: Float = 0.000_1
    ) -> Bool {
        for column in 0..<4 {
            let delta = lhs[column] - rhs[column]
            if simd_reduce_max(simd_abs(delta)) > tolerance {
                return false
            }
        }
        return true
    }
}
