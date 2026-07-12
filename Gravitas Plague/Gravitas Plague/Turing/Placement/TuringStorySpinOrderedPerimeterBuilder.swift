import Foundation
import simd

struct TuringStorySpinOrderedPerimeterBuilder: Sendable {
    func build(
        perimeter: TuringStoryRoomPerimeter,
        spin: TuringStoryScanSpinResult
    ) throws -> TuringStorySpinOrderedPerimeter {
        guard perimeter.wallsClockwise.isEmpty == false else {
            throw TuringStoryWallSliceError.noWalls
        }
        let spinSign: Float = spin.direction == .counterClockwise ? 1 : -1
        let ordered = perimeter.wallsClockwise.sorted { lhs, rhs in
            let lhsDelta = directedDelta(
                wall: lhs,
                center: perimeter.roomCenterXZ,
                startYawRadians: spin.startYawRadians,
                spinSign: spinSign
            )
            let rhsDelta = directedDelta(
                wall: rhs,
                center: perimeter.roomCenterXZ,
                startYawRadians: spin.startYawRadians,
                spinSign: spinSign
            )
            if abs(lhsDelta - rhsDelta) > 0.0001 { return lhsDelta < rhsDelta }
            if lhs.midpointXZ.x != rhs.midpointXZ.x { return lhs.midpointXZ.x < rhs.midpointXZ.x }
            if lhs.midpointXZ.y != rhs.midpointXZ.y { return lhs.midpointXZ.y < rhs.midpointXZ.y }
            return lhs.representativeWallUUID.uuidString < rhs.representativeWallUUID.uuidString
        }

        let walls = ordered.enumerated().map { offset, wall in
            let ordinal = offset + 1
            let start = spin.direction == .clockwise ? wall.startXZ : wall.endXZ
            let end = spin.direction == .clockwise ? wall.endXZ : wall.startXZ
            return TuringStorySpinOrderedWall(
                wallOrdinal: ordinal,
                publicWallID: "wall-\(ordinal)",
                sourceWallID: wall.wallID,
                representativeWallUUID: wall.representativeWallUUID,
                startXZ: start,
                endXZ: end,
                widthMeters: wall.widthMeters,
                heightMeters: wall.heightMeters,
                stability: wall.stability,
                sourceCandidateCount: wall.sourceCandidateCount,
                aggregateFloorFrontageScore: wall.aggregateFloorFrontageScore,
                runtimeWall: wall.runtimeWall
            )
        }
        return TuringStorySpinOrderedPerimeter(
            scanID: perimeter.scanID,
            spinDirection: spin.direction,
            startYawRadians: spin.startYawRadians,
            roomCenterXZ: perimeter.roomCenterXZ,
            floorWorldY: perimeter.floorWorldY,
            isClosed: perimeter.isClosed,
            walls: walls
        )
    }

    private func directedDelta(
        wall: TuringStoryPerimeterWall,
        center: SIMD2<Float>,
        startYawRadians: Float,
        spinSign: Float
    ) -> Float {
        let offset = wall.midpointXZ - center
        let wallYaw = atan2(offset.x, offset.y)
        return positiveModulo(
            (wallYaw - startYawRadians) * spinSign,
            2 * .pi
        )
    }

    private func positiveModulo(_ value: Float, _ modulus: Float) -> Float {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }
}
