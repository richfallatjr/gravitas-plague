import Foundation
import simd

enum TuringStoryScanCleanserTuning {
    static let minimumWallWidth: Float = 0.55
    static let minimumWallHeight: Float = 0.75
    static let maximumNormalAngleDegrees: Float = 8.0
    static let maximumPlaneSeparationMeters: Float = 0.10
    static let maximumProjectedFragmentGapMeters: Float = 0.25
    static let maximumFloorHeightDeltaMeters: Float = 0.08
}

struct TuringStoryCanonicalFloor: Sendable {
    let worldY: Float
    let totalArea: Float
    let confidence: Float
    let sourceFloors: [FloorCandidate]
}

struct TuringStoryCanonicalWall: Sendable, Hashable {
    let representativeWallUUID: UUID
    let sourceWallUUIDs: [UUID]
    let center: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let normal: SIMD3<Float>
    let width: Float
    let height: Float
    let stability: Float
    let representativeCenterSnapshot: SIMD3<Float>
    let representativeNormalSnapshot: SIMD3<Float>
}

struct TuringStoryCleansedRoom: Sendable {
    let scanID: String
    let viewerPosition: SIMD3<Float>
    let viewerForward: SIMD3<Float>
    let floor: TuringStoryCanonicalFloor
    let walls: [TuringStoryCanonicalWall]
    let rawWallByID: [UUID: WallCandidate]
    let fixedOccupancy: [WallPropOccupancyRecord]
}

struct TuringStoryRoomScanCleanser: Sendable {
    private struct NormalizedWall: Sendable {
        let source: WallCandidate
        let center: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let normal: SIMD3<Float>
        let width: Float
        let height: Float
    }

    func cleanse(
        walls rawWalls: [WallCandidate],
        floors rawFloors: [FloorCandidate],
        occupancy rawOccupancy: [WallPropOccupancyRecord],
        viewerPosition: SIMD3<Float>,
        viewerForward: SIMD3<Float>,
        scanID: String
    ) throws -> TuringStoryCleansedRoom {
        let floor = try selectFloor(rawFloors, viewerY: viewerPosition.y)
        let normalized = rawWalls.compactMap {
            normalize($0, viewerPosition: viewerPosition)
        }
        guard !normalized.isEmpty else {
            throw TuringStoryHotspotLayoutError.noCanonicalWalls
        }
        let canonical = connectedComponents(normalized).map(makeCanonicalWall)
        guard !canonical.isEmpty else {
            throw TuringStoryHotspotLayoutError.noCanonicalWalls
        }
        let plannedKinds: Set<WallPropOccupancyKind> = [
            .storyDoorBundle,
            .storyRollingBenchBundle,
            .storyWindowBundle,
            .storyWalkieBundle,
            .wallPoster
        ]
        return TuringStoryCleansedRoom(
            scanID: scanID,
            viewerPosition: viewerPosition,
            viewerForward: viewerForward,
            floor: floor,
            walls: canonical,
            rawWallByID: Dictionary(uniqueKeysWithValues: rawWalls.map { ($0.id, $0) }),
            fixedOccupancy: rawOccupancy.filter { !plannedKinds.contains($0.kind) }
        )
    }

    private func normalize(
        _ wall: WallCandidate,
        viewerPosition: SIMD3<Float>
    ) -> NormalizedWall? {
        guard wall.center.turingFinite,
              wall.normal.turingFinite,
              wall.up.turingFinite,
              wall.right.turingFinite,
              wall.width.isFinite,
              wall.height.isFinite,
              wall.width >= TuringStoryScanCleanserTuning.minimumWallWidth,
              wall.height >= TuringStoryScanCleanserTuning.minimumWallHeight else {
            return nil
        }
        var up = turingStoryUnit(wall.up, fallback: SIMD3<Float>(0, 1, 0))
        if simd_dot(up, SIMD3<Float>(0, 1, 0)) < 0 { up = -up }
        var normal = turingStoryUnit(wall.normal, fallback: SIMD3<Float>(0, 0, 1))
        if simd_dot(normal, viewerPosition - wall.center) < 0 { normal = -normal }
        let right = turingStoryUnit(
            simd_cross(up, normal),
            fallback: turingStoryUnit(wall.right, fallback: SIMD3<Float>(1, 0, 0))
        )
        normal = turingStoryUnit(simd_cross(right, up), fallback: normal)
        return NormalizedWall(
            source: wall,
            center: wall.center,
            right: right,
            up: up,
            normal: normal,
            width: wall.width,
            height: wall.height
        )
    }

    private func connectedComponents(
        _ walls: [NormalizedWall]
    ) -> [[NormalizedWall]] {
        let ordered = walls.sorted { $0.source.id.uuidString < $1.source.id.uuidString }
        var links = Array(repeating: [Int](), count: ordered.count)
        if ordered.count > 1 {
            for lhs in 0..<(ordered.count - 1) {
                for rhs in (lhs + 1)..<ordered.count where canMerge(ordered[lhs], ordered[rhs]) {
                    links[lhs].append(rhs)
                    links[rhs].append(lhs)
                }
            }
        }
        var visited = Set<Int>()
        return ordered.indices.compactMap { start in
            guard visited.insert(start).inserted else { return nil }
            var stack = [start]
            var component: [NormalizedWall] = []
            while let current = stack.popLast() {
                component.append(ordered[current])
                for next in links[current] where visited.insert(next).inserted {
                    stack.append(next)
                }
            }
            return component
        }
    }

    private func canMerge(_ lhs: NormalizedWall, _ rhs: NormalizedWall) -> Bool {
        let normalThreshold = cos(
            TuringStoryScanCleanserTuning.maximumNormalAngleDegrees * .pi / 180
        )
        guard abs(simd_dot(lhs.normal, rhs.normal)) >= normalThreshold else { return false }
        let delta = rhs.center - lhs.center
        guard max(
            abs(simd_dot(delta, lhs.normal)),
            abs(simd_dot(delta, rhs.normal))
        ) <= TuringStoryScanCleanserTuning.maximumPlaneSeparationMeters else {
            return false
        }
        let a = projectedBounds(lhs, basis: lhs)
        let b = projectedBounds(rhs, basis: lhs)
        return intervalGap(a.minX, a.maxX, b.minX, b.maxX)
                <= TuringStoryScanCleanserTuning.maximumProjectedFragmentGapMeters &&
            intervalGap(a.minY, a.maxY, b.minY, b.maxY)
                <= TuringStoryScanCleanserTuning.maximumProjectedFragmentGapMeters
    }

    private func makeCanonicalWall(_ members: [NormalizedWall]) -> TuringStoryCanonicalWall {
        let seed = members.sorted { $0.source.id.uuidString < $1.source.id.uuidString }[0]
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for member in members {
            let bounds = projectedBounds(member, basis: seed)
            minX = min(minX, bounds.minX)
            maxX = max(maxX, bounds.maxX)
            minY = min(minY, bounds.minY)
            maxY = max(maxY, bounds.maxY)
        }
        let representative = members.sorted {
            if abs($0.source.stabilityScore - $1.source.stabilityScore) > 0.0001 {
                return $0.source.stabilityScore > $1.source.stabilityScore
            }
            return $0.source.id.uuidString < $1.source.id.uuidString
        }[0]
        let center = seed.center + seed.right * ((minX + maxX) * 0.5) +
            seed.up * ((minY + maxY) * 0.5)
        let stability = members.reduce(Float.zero) {
            $0 + min(1, max(0, $1.source.stabilityScore))
        } / Float(members.count)
        return TuringStoryCanonicalWall(
            representativeWallUUID: representative.source.id,
            sourceWallUUIDs: members.map(\.source.id).sorted { $0.uuidString < $1.uuidString },
            center: center,
            right: seed.right,
            up: seed.up,
            normal: seed.normal,
            width: maxX - minX,
            height: maxY - minY,
            stability: stability,
            representativeCenterSnapshot: representative.center,
            representativeNormalSnapshot: representative.normal
        )
    }

    private func projectedBounds(
        _ wall: NormalizedWall,
        basis: NormalizedWall
    ) -> TuringStorySemanticRect {
        let halfRight = wall.right * (wall.width * 0.5)
        let halfUp = wall.up * (wall.height * 0.5)
        let corners: [SIMD3<Float>] = [
            wall.center - halfRight - halfUp,
            wall.center + halfRight - halfUp,
            wall.center - halfRight + halfUp,
            wall.center + halfRight + halfUp
        ]
        let projected = corners.map { point -> SIMD2<Float> in
            let delta = point - basis.center
            return SIMD2<Float>(simd_dot(delta, basis.right), simd_dot(delta, basis.up))
        }
        return TuringStorySemanticRect(
            minX: projected.map(\.x).min() ?? 0,
            minY: projected.map(\.y).min() ?? 0,
            maxX: projected.map(\.x).max() ?? 0,
            maxY: projected.map(\.y).max() ?? 0
        )
    }

    private func intervalGap(
        _ lhsMin: Float, _ lhsMax: Float, _ rhsMin: Float, _ rhsMax: Float
    ) -> Float {
        if lhsMax < rhsMin { return rhsMin - lhsMax }
        if rhsMax < lhsMin { return lhsMin - rhsMax }
        return 0
    }

    private func selectFloor(
        _ floors: [FloorCandidate],
        viewerY: Float
    ) throws -> TuringStoryCanonicalFloor {
        let candidates = floors.filter {
            $0.isUsableFloor && (viewerY - $0.worldY) >= 1.0 && (viewerY - $0.worldY) <= 2.4
        }.sorted { $0.worldY < $1.worldY }
        guard !candidates.isEmpty else { throw TuringStoryHotspotLayoutError.noUsableFloor }
        var groups: [[FloorCandidate]] = []
        for floor in candidates {
            if let index = groups.firstIndex(where: { group in
                group.contains {
                    abs($0.worldY - floor.worldY)
                        <= TuringStoryScanCleanserTuning.maximumFloorHeightDeltaMeters
                }
            }) {
                groups[index].append(floor)
            } else {
                groups.append([floor])
            }
        }
        let selected = groups.sorted { lhs, rhs in
            let lhsArea = lhs.reduce(Float.zero) { $0 + $1.area }
            let rhsArea = rhs.reduce(Float.zero) { $0 + $1.area }
            if abs(lhsArea - rhsArea) > 0.0001 { return lhsArea > rhsArea }
            return lhs.reduce(Float.zero) { $0 + $1.stabilityScore } >
                rhs.reduce(Float.zero) { $0 + $1.stabilityScore }
        }[0]
        let area = selected.reduce(Float.zero) { $0 + $1.area }
        return TuringStoryCanonicalFloor(
            worldY: selected.reduce(Float.zero) { $0 + $1.worldY * $1.area } / max(area, 0.001),
            totalArea: area,
            confidence: selected.reduce(Float.zero) {
                $0 + min(1, max(0, $1.stabilityScore)) * $1.area
            } / max(area, 0.001),
            sourceFloors: selected
        )
    }
}

func turingStoryUnit(
    _ value: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let magnitude = simd_length(value)
    guard magnitude.isFinite, magnitude > 0.0001 else { return fallback }
    return value / magnitude
}

private extension SIMD3 where Scalar == Float {
    var turingFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
