import Foundation

struct TuringStoryResolvedSliceAssignment: Sendable {
    let propID: TuringStoryPropID
    let sliceIDs: [String]
    let placement: TuringStoryExactPlacement
}

struct TuringStoryResolvedSliceLayout: Sendable {
    let scanID: String
    let assignments: [TuringStoryResolvedSliceAssignment]
    let distinctWallCount: Int
}

struct TuringStoryWallSliceLayoutResolver: Sendable {
    func resolve(
        plan: TuringStoryWallSlicePlan,
        map: TuringStoryWallSliceMap,
        catalog: TuringStoryExactPlacementCatalog
    ) throws -> TuringStoryResolvedSliceLayout {
        var issues: [String] = []

        let requested: [(TuringStoryPropID, [String]?)] = [
            (.door, plan.d),
            (.window, plan.w),
            (.walkieShelf, plan.s),
            (.poster, plan.p)
        ]
        let sliceByID = map.sliceByID
        var validatedGroups: [(TuringStoryPropID, [TuringStoryWallSlice])] = []

        for (propID, ids) in requested {
            guard let ids, ids.isEmpty == false else { continue }
            let slices = ids.compactMap { sliceByID[$0] }
            if slices.count != ids.count {
                let unknown = ids.filter { sliceByID[$0] == nil }
                issues.append("\(propID.rawValue) used unknown slices \(unknown.joined(separator: ","))")
                continue
            }
            validatedGroups.append((propID, slices))
        }

        guard issues.isEmpty else {
            throw TuringStoryWallSliceError.invalidPlan(issues)
        }

        let assignments = try validatedGroups.map { propID, slices in
            let intervalMin = slices.map(\.localMinX).min() ?? 0
            let intervalMax = slices.map(\.localMaxX).max() ?? 0
            let targetX = (intervalMin + intervalMax) * 0.5
            let wallUUID = slices[0].representativeWallUUID
            let candidates = catalog.placements(for: propID).filter {
                $0.wallUUID == wallUUID &&
                    $0.localX >= intervalMin - 0.001 &&
                    $0.localX <= intervalMax + 0.001
            }
            guard let exact = candidates.min(by: {
                let lhs = abs($0.localX - targetX)
                let rhs = abs($1.localX - targetX)
                if lhs != rhs { return lhs < rhs }
                return $0.placementID < $1.placementID
            }) else {
                throw TuringStoryWallSliceError.noExactPlacement(propID.rawValue)
            }
            return TuringStoryResolvedSliceAssignment(
                propID: propID,
                sliceIDs: slices.map(\.sliceID),
                placement: exact
            )
        }

        let wallOrdinals = Set(validatedGroups.compactMap { $0.1.first?.wallOrdinal })
        let selectedIDs = validatedGroups.flatMap { $0.1.map(\.sliceID) }
        let reusedSliceCount = selectedIDs.count - Set(selectedIDs).count
        logSelections(
            assignments: assignments,
            distinctWallCount: wallOrdinals.count,
            reusedSliceCount: reusedSliceCount
        )
        print("[TuringWallSlices] plan resolved fallbackUsed=false")
        return TuringStoryResolvedSliceLayout(
            scanID: map.perimeter.scanID,
            assignments: assignments.sorted { $0.propID.priority < $1.propID.priority },
            distinctWallCount: wallOrdinals.count
        )
    }

    private func logSelections(
        assignments: [TuringStoryResolvedSliceAssignment],
        distinctWallCount: Int,
        reusedSliceCount: Int
    ) {
        func value(_ propID: TuringStoryPropID) -> String {
            assignments.first(where: { $0.propID == propID })?
                .sliceIDs.joined(separator: ",") ?? "null"
        }
        func wall(_ propID: TuringStoryPropID) -> String {
            guard let id = assignments.first(where: { $0.propID == propID })?
                .sliceIDs.first,
                  let numeric = Int(id) else { return "null" }
            return String(numeric / 10)
        }
        print(
            """
            [TuringWallSlices] selections
              door: \(value(.door))
              doorWall: \(wall(.door))
              window: \(value(.window))
              windowWall: \(wall(.window))
              walkieShelf: \(value(.walkieShelf))
              walkieWall: \(wall(.walkieShelf))
              poster: \(value(.poster))
              posterWall: \(wall(.poster))
              reusedSliceCount: \(reusedSliceCount)
              distinctWallCount: \(distinctWallCount)
              separateWallPreferenceSatisfied: \(distinctWallCount == assignments.count)
            """
        )
    }
}
