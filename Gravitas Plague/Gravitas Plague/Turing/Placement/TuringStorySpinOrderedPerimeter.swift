import Foundation
import simd

struct TuringStorySpinOrderedWall: Sendable, Hashable {
    let wallOrdinal: Int
    let publicWallID: String
    let sourceWallID: String
    let representativeWallUUID: UUID
    let startXZ: SIMD2<Float>
    let endXZ: SIMD2<Float>
    let widthMeters: Float
    let heightMeters: Float
    let stability: Float
    let sourceCandidateCount: Int
    let aggregateFloorFrontageScore: Float
    let runtimeWall: TuringStoryCanonicalWall
}

struct TuringStorySpinOrderedPerimeter: Sendable {
    let scanID: String
    let spinDirection: TuringStoryScanSpinDirection
    let startYawRadians: Float
    let roomCenterXZ: SIMD2<Float>
    let floorWorldY: Float
    let isClosed: Bool
    let walls: [TuringStorySpinOrderedWall]
}
