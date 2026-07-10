import Foundation

struct TuringStoryPlacementHotspotCompressor: Sendable {
    private struct Draft: Sendable {
        let propID: TuringStoryPropID
        let wallID: String
        let wallUUID: UUID
        let placements: [TuringStoryExactPlacement]

        var quality: Float { placements.map(\.deterministicQuality).max() ?? 0 }
        var minimumLocalX: Float { placements.first?.localX ?? 0 }
        var maximumLocalX: Float { placements.last?.localX ?? 0 }
    }

    private let contiguousGap: Float = 0.15
    private let oversizedRunWidth: Float = 1.40
    private let maximumSubrangeWidth: Float = 1.20
    private let maximumPerProp = 8
    private let maximumPerPropPerWall = 3

    func compress(
        catalog: TuringStoryExactPlacementCatalog,
        perimeter: TuringStoryRoomPerimeter,
        maximumTotal: Int = 32
    ) throws -> TuringStoryHotspotAtlas {
        let wallOrder = Dictionary(
            uniqueKeysWithValues: perimeter.wallsClockwise.enumerated().map { ($0.element.wallID, $0.offset) }
        )
        var drafts: [Draft] = []
        let grouped = Dictionary(grouping: catalog.placements) {
            "\($0.propID.rawValue)|\($0.wallID)"
        }
        for key in grouped.keys.sorted() {
            guard let placements = grouped[key] else { continue }
            for run in contiguousRuns(placements) {
                drafts.append(contentsOf: splitOversized(run).map {
                    Draft(
                        propID: $0[0].propID,
                        wallID: $0[0].wallID,
                        wallUUID: $0[0].wallUUID,
                        placements: $0
                    )
                })
            }
        }

        let capacityPerProp = min(
            maximumPerProp,
            max(4, maximumTotal / TuringStoryPropID.allCases.count)
        )
        var selected: [Draft] = []
        for propID in TuringStoryPropID.allCases.sorted(by: { $0.priority < $1.priority }) {
            var propDrafts = drafts.filter { $0.propID == propID }
            propDrafts = limitPerWall(propDrafts)
            selected.append(contentsOf: selectDiverse(propDrafts, capacity: capacityPerProp))
        }
        if selected.count > maximumTotal {
            selected = Array(selected.sorted(by: draftQualityOrder).prefix(maximumTotal))
        }
        selected.sort {
            if $0.propID.priority != $1.propID.priority {
                return $0.propID.priority < $1.propID.priority
            }
            let lhsWall = wallOrder[$0.wallID] ?? Int.max
            let rhsWall = wallOrder[$1.wallID] ?? Int.max
            if lhsWall != rhsWall { return lhsWall < rhsWall }
            if $0.minimumLocalX != $1.minimumLocalX { return $0.minimumLocalX < $1.minimumLocalX }
            return $0.maximumLocalX < $1.maximumLocalX
        }

        var counters: [TuringStoryPropID: Int] = [:]
        let hotspots = selected.map { draft -> TuringStoryPlacementHotspot in
            let counter = counters[draft.propID, default: 0]
            counters[draft.propID] = counter + 1
            let recommended = recommendedPlacement(draft.placements)
            return TuringStoryPlacementHotspot(
                hotspotID: "\(draft.propID.shortID)\(counter)",
                propID: draft.propID,
                wallID: draft.wallID,
                wallUUID: draft.wallUUID,
                minimumLocalX: draft.minimumLocalX,
                maximumLocalX: draft.maximumLocalX,
                recommendedLocalX: recommended.localX,
                exactPlacementIDs: draft.placements.map(\.placementID),
                bestFloorFrontageScore: draft.placements.map(\.floorFrontageScore).max() ?? 0,
                meanFloorFrontageScore: draft.placements.reduce(0) { $0 + $1.floorFrontageScore } /
                    Float(max(1, draft.placements.count)),
                floorEvidenceKnown: draft.placements.contains(where: \.floorEvidenceKnown),
                bestWallCenterScore: draft.placements.map(\.wallCenterScore).max() ?? 0,
                bestCornerClearanceScore: draft.placements.map(\.cornerClearanceScore).max() ?? 0,
                wallStabilityScore: draft.placements.map(\.wallStabilityScore).max() ?? 0,
                deterministicQuality: recommended.deterministicQuality
            )
        }
        guard !hotspots.isEmpty else { throw TuringStoryHotspotLayoutError.noHotspotAtlas }
        let map = Dictionary(uniqueKeysWithValues: hotspots.map { ($0.hotspotID, $0) })
        return TuringStoryHotspotAtlas(
            hotspots: hotspots,
            hotspotByID: map,
            unavoidableConflicts: unavoidableConflicts(hotspots, catalog: catalog)
        )
    }

    private func contiguousRuns(
        _ values: [TuringStoryExactPlacement]
    ) -> [[TuringStoryExactPlacement]] {
        let ordered = values.sorted { $0.localX < $1.localX }
        var runs: [[TuringStoryExactPlacement]] = []
        for placement in ordered {
            if let last = runs.last?.last,
               placement.localX - last.localX <= contiguousGap {
                runs[runs.count - 1].append(placement)
            } else {
                runs.append([placement])
            }
        }
        return runs
    }

    private func splitOversized(
        _ run: [TuringStoryExactPlacement]
    ) -> [[TuringStoryExactPlacement]] {
        guard let first = run.first, let last = run.last,
              last.localX - first.localX > oversizedRunWidth else {
            return [run]
        }
        var result: [[TuringStoryExactPlacement]] = []
        var current: [TuringStoryExactPlacement] = []
        var startX = first.localX
        for placement in run {
            if !current.isEmpty,
               placement.localX - startX > maximumSubrangeWidth {
                result.append(current)
                current = []
                startX = placement.localX
            }
            current.append(placement)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func limitPerWall(_ drafts: [Draft]) -> [Draft] {
        Dictionary(grouping: drafts, by: \.wallID).values.flatMap { values in
            values.sorted(by: draftQualityOrder).prefix(maximumPerPropPerWall)
        }
    }

    private func selectDiverse(_ drafts: [Draft], capacity: Int) -> [Draft] {
        guard drafts.count > capacity else { return drafts }
        let grouped = Dictionary(grouping: drafts, by: \.wallID)
        var selected = grouped.keys.sorted().compactMap { wallID in
            grouped[wallID]?.sorted(by: draftQualityOrder).first
        }.sorted(by: draftQualityOrder)
        if selected.count > capacity { return Array(selected.prefix(capacity)) }
        let selectedKeys = Set(selected.map { key($0) })
        let remaining = drafts.filter { !selectedKeys.contains(key($0)) }
            .sorted(by: draftQualityOrder)
        selected.append(contentsOf: remaining.prefix(capacity - selected.count))
        return selected
    }

    private func recommendedPlacement(
        _ placements: [TuringStoryExactPlacement]
    ) -> TuringStoryExactPlacement {
        placements.sorted {
            if $0.deterministicQuality != $1.deterministicQuality {
                return $0.deterministicQuality > $1.deterministicQuality
            }
            if $0.floorFrontageScore != $1.floorFrontageScore {
                return $0.floorFrontageScore > $1.floorFrontageScore
            }
            if $0.wallCenterScore != $1.wallCenterScore {
                return $0.wallCenterScore > $1.wallCenterScore
            }
            if $0.cornerClearanceScore != $1.cornerClearanceScore {
                return $0.cornerClearanceScore > $1.cornerClearanceScore
            }
            if abs($0.localX) != abs($1.localX) { return abs($0.localX) < abs($1.localX) }
            return $0.placementID < $1.placementID
        }[0]
    }

    private func unavoidableConflicts(
        _ hotspots: [TuringStoryPlacementHotspot],
        catalog: TuringStoryExactPlacementCatalog
    ) -> [[String]] {
        guard hotspots.count > 1 else { return [] }
        var conflicts: [[String]] = []
        for lhsIndex in 0..<(hotspots.count - 1) {
            for rhsIndex in (lhsIndex + 1)..<hotspots.count {
                let lhs = hotspots[lhsIndex]
                let rhs = hotspots[rhsIndex]
                guard lhs.propID != rhs.propID, lhs.wallID == rhs.wallID else { continue }
                let lhsExact = lhs.exactPlacementIDs.compactMap { catalog.placementByID[$0] }
                let rhsExact = rhs.exactPlacementIDs.compactMap { catalog.placementByID[$0] }
                let hasCompatiblePair = lhsExact.contains { a in
                    rhsExact.contains { b in !a.semanticRect.overlaps(b.semanticRect) }
                }
                if !hasCompatiblePair { conflicts.append([lhs.hotspotID, rhs.hotspotID]) }
            }
        }
        return conflicts
    }

    private func key(_ draft: Draft) -> String {
        "\(draft.propID.rawValue)|\(draft.wallID)|\(draft.minimumLocalX)|\(draft.maximumLocalX)"
    }

    private func draftQualityOrder(_ lhs: Draft, _ rhs: Draft) -> Bool {
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        if lhs.wallID != rhs.wallID { return lhs.wallID < rhs.wallID }
        return lhs.minimumLocalX < rhs.minimumLocalX
    }
}
