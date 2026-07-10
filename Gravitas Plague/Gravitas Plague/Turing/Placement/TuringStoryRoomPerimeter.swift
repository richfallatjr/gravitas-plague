import Foundation
import simd

struct TuringStoryPerimeterWall: Sendable, Hashable {
    let wallID: String
    let representativeWallUUID: UUID
    let startXZ: SIMD2<Float>
    let endXZ: SIMD2<Float>
    let heightMeters: Float
    let stability: Float
    let sourceCandidateCount: Int
    let aggregateFloorFrontageScore: Float
    let runtimeWall: TuringStoryCanonicalWall

    var midpointXZ: SIMD2<Float> { (startXZ + endXZ) * 0.5 }
    var widthMeters: Float { simd_length(endXZ - startXZ) }
}

struct TuringStoryRoomPerimeter: Sendable {
    let scanID: String
    let floorWorldY: Float
    let roomCenterXZ: SIMD2<Float>
    let isClosed: Bool
    let wallsClockwise: [TuringStoryPerimeterWall]
    let wallIDBySourceUUID: [UUID: String]

    var wallByID: [String: TuringStoryPerimeterWall] {
        Dictionary(uniqueKeysWithValues: wallsClockwise.map { ($0.wallID, $0) })
    }
}
