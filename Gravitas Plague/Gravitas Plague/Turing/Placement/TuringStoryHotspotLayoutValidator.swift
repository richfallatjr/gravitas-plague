import Foundation
import simd

struct TuringStoryValidatedHotspotAssignment: Sendable {
    let propID: TuringStoryPropID
    let hotspotID: String
    let normalizedPosition: Float
    let placement: TuringStoryExactPlacement
}

struct TuringStoryValidatedHotspotLayout: Sendable {
    let scanID: String
    let assignments: [TuringStoryValidatedHotspotAssignment]
    let placementVector: TuringStoryFeasibilityVector
}

struct TuringStoryHotspotLayoutValidator: Sendable {
    private struct RankedCandidate {
        let rank: Int
        let assignment: TuringStoryValidatedHotspotAssignment
    }

    private struct RankedResolution {
        let candidates: [RankedCandidate]

        var rankPenalty: Int {
            candidates.reduce(0) { $0 + ($1.rank - 1) }
        }

        var stableID: String {
            candidates
                .sorted { $0.assignment.propID.priority < $1.assignment.propID.priority }
                .map { $0.assignment.placement.placementID }
                .joined(separator: "|")
        }
    }

    private struct RequestedSelection {
        let propID: TuringStoryPropID
        let selection: TuringHotspotSelection
        let hotspot: TuringStoryPlacementHotspot
        let requestedX: Float
        let candidates: [TuringStoryExactPlacement]
    }

    private struct Resolution {
        let assignments: [TuringStoryValidatedHotspotAssignment]
        let normalizedDistance: Float
        let quality: Float
        let stableID: String
    }

    private let maximumWallCenterDrift: Float = 0.10
    private let maximumWallNormalDeltaDegrees: Float = 8.0

    func acceptPromptSelections(
        plan: TuringStoryHotspotPlan,
        context: TuringStoryHotspotPlanningContext,
        atlas: TuringStoryHotspotAtlas
    ) -> TuringStoryValidatedHotspotLayout {
        if plan.v != 1 || plan.scan != context.perimeter.scanID {
            print(
                "[TuringWallHotspotDedup] response identity normalized expectedScan=\(context.perimeter.scanID) returnedScan=\(plan.scan) returnedVersion=\(plan.v) runFails=false"
            )
        }

        let rankedSelections: [(TuringStoryPropID, [TuringHotspotSelection])] = [
            (.door, [plan.a.d, plan.b?.d].compactMap { $0 }),
            (.window, [plan.a.w, plan.b?.w].compactMap { $0 }),
            (.walkieShelf, [plan.a.s, plan.b?.s].compactMap { $0 }),
            (.poster, [plan.a.p, plan.b?.p].compactMap { $0 })
        ]
        var options: [TuringStoryPropID: [RankedCandidate]] = [:]

        for (propID, selections) in rankedSelections {
            for (candidateOffset, selection) in selections.prefix(2).enumerated() {
                let rank = candidateOffset + 1
                guard selection.normalizedPosition.isFinite,
                      let hotspot = atlas.hotspotByID[selection.hotspotID],
                      hotspot.propID == propID else {
                    print(
                        "[TuringWallHotspotDedup] candidate rejected prop=\(propID.rawValue) rank=\(rank) hotspotID=\(selection.hotspotID) reason=unresolvable runFails=false"
                    )
                    continue
                }
                let u = min(1, max(0, selection.normalizedPosition))
                let requestedX = hotspot.minimumLocalX + u *
                    (hotspot.maximumLocalX - hotspot.minimumLocalX)
                let candidates = hotspot.exactPlacementIDs.compactMap {
                    context.catalog.placementByID[$0]
                }
                guard let exact = candidates.min(by: { lhs, rhs in
                    let lhsDistance = abs(lhs.localX - requestedX)
                    let rhsDistance = abs(rhs.localX - requestedX)
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                    return lhs.placementID < rhs.placementID
                }) else {
                    print(
                        "[TuringWallHotspotDedup] candidate rejected prop=\(propID.rawValue) rank=\(rank) hotspotID=\(selection.hotspotID) reason=noExactPlacement runFails=false"
                    )
                    continue
                }
                options[propID, default: []].append(
                    RankedCandidate(
                        rank: rank,
                        assignment: TuringStoryValidatedHotspotAssignment(
                            propID: propID,
                            hotspotID: selection.hotspotID,
                            normalizedPosition: u,
                            placement: exact
                        )
                    )
                )
            }
        }

        let propOrder = TuringStoryPropID.allCases.sorted {
            $0.priority < $1.priority
        }
        let resolution = bestRankedResolution(
            propOrder: propOrder,
            options: options,
            index: 0,
            chosen: []
        )
        let acceptedCandidates = resolution?.candidates ?? []
        let accepted = acceptedCandidates.map(\.assignment)

        for propID in propOrder {
            guard let selected = acceptedCandidates.first(where: {
                $0.assignment.propID == propID
            }) else {
                print(
                    "[TuringWallHotspotDedup] prop skipped prop=\(propID.rawValue) reason=noCompatibleGlobalCombination runFails=false"
                )
                continue
            }
            if selected.rank == 2 {
                print(
                    "[TuringWallHotspotDedup] candidate one replaced prop=\(propID.rawValue) reason=globalDedup selectedRank=2 runFails=false"
                )
            }
            let assignment = selected.assignment
            print(
                "[TuringWallHotspotDedup] candidate accepted prop=\(propID.rawValue) rank=\(selected.rank) hotspotID=\(assignment.hotspotID) wallID=\(assignment.placement.wallID) exactPlacementID=\(assignment.placement.placementID) localX=\(assignment.placement.localX)"
            )
        }
        print(
            "[TuringWallHotspotDedup] global resolution finished placed=\(accepted.count)/\(propOrder.count) rankPenalty=\(resolution?.rankPenalty ?? 0) stableID=\(resolution?.stableID ?? "none") runFails=false"
        )

        let vector = TuringStoryFeasibilityVector(
            door: accepted.contains(where: { $0.propID == .door }) ? 1 : 0,
            window: accepted.contains(where: { $0.propID == .window }) ? 1 : 0,
            walkieShelf: accepted.contains(where: { $0.propID == .walkieShelf }) ? 1 : 0,
            poster: accepted.contains(where: { $0.propID == .poster }) ? 1 : 0
        )
        return TuringStoryValidatedHotspotLayout(
            scanID: context.perimeter.scanID,
            assignments: accepted.sorted { $0.propID.priority < $1.propID.priority },
            placementVector: vector
        )
    }

    private func bestRankedResolution(
        propOrder: [TuringStoryPropID],
        options: [TuringStoryPropID: [RankedCandidate]],
        index: Int,
        chosen: [RankedCandidate]
    ) -> RankedResolution? {
        guard index < propOrder.count else {
            return RankedResolution(candidates: chosen)
        }

        let propID = propOrder[index]
        var best = bestRankedResolution(
            propOrder: propOrder,
            options: options,
            index: index + 1,
            chosen: chosen
        )
        for candidate in options[propID] ?? [] where isCompatible(candidate, with: chosen) {
            let result = bestRankedResolution(
                propOrder: propOrder,
                options: options,
                index: index + 1,
                chosen: chosen + [candidate]
            )
            if isBetterRankedResolution(result, than: best, propOrder: propOrder) {
                best = result
            }
        }
        return best
    }

    private func isCompatible(
        _ candidate: RankedCandidate,
        with chosen: [RankedCandidate]
    ) -> Bool {
        for existing in chosen {
            let lhs = candidate.assignment
            let rhs = existing.assignment
            guard lhs.placement.wallID == rhs.placement.wallID else { continue }
            if lhs.placement.runtimeSemanticRect.overlaps(
                rhs.placement.runtimeSemanticRect
            ) {
                return false
            }
            let isDoorWindowPair =
                (lhs.propID == .door && rhs.propID == .window) ||
                (lhs.propID == .window && rhs.propID == .door)
            if isDoorWindowPair {
                return false
            }
        }
        return true
    }

    private func isBetterRankedResolution(
        _ candidate: RankedResolution?,
        than current: RankedResolution?,
        propOrder: [TuringStoryPropID]
    ) -> Bool {
        guard let candidate else { return false }
        guard let current else { return true }
        if candidate.candidates.count != current.candidates.count {
            return candidate.candidates.count > current.candidates.count
        }
        for propID in propOrder {
            let candidateHasProp = candidate.candidates.contains {
                $0.assignment.propID == propID
            }
            let currentHasProp = current.candidates.contains {
                $0.assignment.propID == propID
            }
            if candidateHasProp != currentHasProp {
                return candidateHasProp
            }
        }
        if candidate.rankPenalty != current.rankPenalty {
            return candidate.rankPenalty < current.rankPenalty
        }
        return candidate.stableID < current.stableID
    }

    func validate(
        plan: TuringStoryHotspotPlan,
        context: TuringStoryHotspotPlanningContext,
        atlas: TuringStoryHotspotAtlas,
        liveWalls: [UUID: WallCandidate]
    ) throws -> TuringStoryValidatedHotspotLayout {
        guard plan.v == 1 else {
            throw TuringStoryHotspotLayoutError.malformedResponse("v must be 1")
        }
        guard plan.scan == context.perimeter.scanID else {
            throw TuringStoryHotspotLayoutError.scanMismatch
        }
        let selections: [(TuringStoryPropID, TuringHotspotSelection?)] = [
            (.door, plan.a.d),
            (.window, plan.a.w),
            (.walkieShelf, plan.a.s),
            (.poster, plan.a.p)
        ]
        let actualVector = selections.map { $0.1 == nil ? 0 : 1 }
        guard actualVector == context.feasibility.compactArray else {
            throw TuringStoryHotspotLayoutError.placementVectorMismatch
        }

        var requests: [RequestedSelection] = []
        for (propID, selection) in selections {
            guard let selection else { continue }
            guard selection.normalizedPosition.isFinite,
                  (0...1).contains(selection.normalizedPosition) else {
                throw TuringStoryHotspotLayoutError.invalidNormalizedPosition(propID.rawValue)
            }
            guard let hotspot = atlas.hotspotByID[selection.hotspotID] else {
                throw TuringStoryHotspotLayoutError.unknownHotspot(selection.hotspotID)
            }
            guard hotspot.propID == propID else {
                throw TuringStoryHotspotLayoutError.hotspotPropMismatch(selection.hotspotID)
            }
            let requestedX = hotspot.minimumLocalX + selection.normalizedPosition *
                (hotspot.maximumLocalX - hotspot.minimumLocalX)
            let candidates = hotspot.exactPlacementIDs.compactMap {
                context.catalog.placementByID[$0]
            }
            guard !candidates.isEmpty else {
                throw TuringStoryHotspotLayoutError.placementResolutionFailed(selection.hotspotID)
            }
            for candidate in candidates {
                try validateLiveWall(candidate, liveWalls: liveWalls)
            }
            requests.append(
                RequestedSelection(
                    propID: propID,
                    selection: selection,
                    hotspot: hotspot,
                    requestedX: requestedX,
                    candidates: candidates
                )
            )
        }
        guard let resolution = resolveJointlyCompatible(
            requests,
            fixed: context.catalog.fixedOccupancy
        ) else {
            throw TuringStoryHotspotLayoutError.placementResolutionFailed(
                requests.map { $0.selection.hotspotID }.joined(separator: ",")
            )
        }
        let resolved = resolution.assignments
        for assignment in resolved {
            let exact = assignment.placement
            print(
                "[TuringWallHotspot] selection resolved prop=\(assignment.propID.rawValue) hotspotID=\(assignment.hotspotID) requestedU=\(assignment.normalizedPosition) exactPlacementID=\(exact.placementID) localX=\(exact.localX)"
            )
        }
        print(
            "[TuringWallHotspot] joint exact resolution passed normalizedDistance=\(resolution.normalizedDistance) stableID=\(resolution.stableID)"
        )
        return TuringStoryValidatedHotspotLayout(
            scanID: plan.scan,
            assignments: resolved.sorted { $0.propID.priority < $1.propID.priority },
            placementVector: context.feasibility
        )
    }

    private func resolveJointlyCompatible(
        _ requests: [RequestedSelection],
        fixed: [TuringStoryCanonicalOccupancy]
    ) -> Resolution? {
        var best: Resolution?
        searchCompatibleAssignments(
            requests,
            fixed: fixed,
            index: 0,
            chosen: [],
            normalizedDistance: 0,
            quality: 0,
            best: &best
        )
        return best
    }

    private func searchCompatibleAssignments(
        _ requests: [RequestedSelection],
        fixed: [TuringStoryCanonicalOccupancy],
        index: Int,
        chosen: [TuringStoryValidatedHotspotAssignment],
        normalizedDistance: Float,
        quality: Float,
        best: inout Resolution?
    ) {
        guard index < requests.count else {
            let stableID = chosen.map { $0.placement.placementID }.joined(separator: "|")
            let candidate = Resolution(
                assignments: chosen,
                normalizedDistance: normalizedDistance,
                quality: quality,
                stableID: stableID
            )
            if isBetter(candidate, than: best) {
                best = candidate
            }
            return
        }

        let request = requests[index]
        let range = max(
            0.001,
            request.hotspot.maximumLocalX - request.hotspot.minimumLocalX
        )
        let ordered = request.candidates.sorted {
            let lhsDistance = abs($0.localX - request.requestedX)
            let rhsDistance = abs($1.localX - request.requestedX)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if $0.deterministicQuality != $1.deterministicQuality {
                return $0.deterministicQuality > $1.deterministicQuality
            }
            return $0.placementID < $1.placementID
        }

        for exact in ordered {
            if chosen.contains(where: {
                $0.placement.wallID == exact.wallID &&
                    $0.placement.semanticRect.overlaps(exact.semanticRect)
            }) {
                continue
            }
            if fixed.contains(where: {
                $0.wallID == exact.wallID && exact.semanticRect.overlaps($0.paddedRect)
            }) {
                continue
            }
            let nextDistance = normalizedDistance + abs(exact.localX - request.requestedX) / range
            if let best, nextDistance > best.normalizedDistance + 0.0001 {
                continue
            }
            let assignment = TuringStoryValidatedHotspotAssignment(
                propID: request.propID,
                hotspotID: request.selection.hotspotID,
                normalizedPosition: request.selection.normalizedPosition,
                placement: exact
            )
            searchCompatibleAssignments(
                requests,
                fixed: fixed,
                index: index + 1,
                chosen: chosen + [assignment],
                normalizedDistance: nextDistance,
                quality: quality + exact.deterministicQuality,
                best: &best
            )
        }
    }

    private func isBetter(
        _ candidate: Resolution,
        than current: Resolution?
    ) -> Bool {
        guard let current else { return true }
        if abs(candidate.normalizedDistance - current.normalizedDistance) > 0.0001 {
            return candidate.normalizedDistance < current.normalizedDistance
        }
        if abs(candidate.quality - current.quality) > 0.0001 {
            return candidate.quality > current.quality
        }
        return candidate.stableID < current.stableID
    }

    func validateLiveWalls(
        layout: TuringStoryValidatedHotspotLayout,
        liveWalls: [UUID: WallCandidate]
    ) throws {
        for assignment in layout.assignments {
            try validateLiveWall(assignment.placement, liveWalls: liveWalls)
        }
    }

    private func validateOverlap(
        _ assignments: [TuringStoryValidatedHotspotAssignment]
    ) throws {
        guard assignments.count > 1 else { return }
        for lhsIndex in 0..<(assignments.count - 1) {
            for rhsIndex in (lhsIndex + 1)..<assignments.count {
                let lhs = assignments[lhsIndex].placement
                let rhs = assignments[rhsIndex].placement
                if lhs.wallID == rhs.wallID && lhs.semanticRect.overlaps(rhs.semanticRect) {
                    throw TuringStoryHotspotLayoutError.selectedOverlap(
                        lhs.placementID,
                        rhs.placementID
                    )
                }
            }
        }
    }

    private func validateFixedOccupancy(
        _ assignments: [TuringStoryValidatedHotspotAssignment],
        fixed: [TuringStoryCanonicalOccupancy]
    ) throws {
        for assignment in assignments {
            let placement = assignment.placement
            if let overlap = fixed.first(where: {
                $0.wallID == placement.wallID && placement.semanticRect.overlaps($0.paddedRect)
            }) {
                throw TuringStoryHotspotLayoutError.fixedOccupancyOverlap(
                    overlap.occupancyID.uuidString
                )
            }
        }
    }

    private func validateLiveWall(
        _ placement: TuringStoryExactPlacement,
        liveWalls: [UUID: WallCandidate]
    ) throws {
        guard let live = liveWalls[placement.wallUUID] else {
            throw TuringStoryHotspotLayoutError.liveWallMissing(placement.wallUUID.uuidString)
        }
        let centerDelta = simd_length(live.center - placement.liveWallCenterSnapshot)
        let lhs = turingStoryUnit(live.normal, fallback: SIMD3<Float>(0, 0, 1))
        let rhs = turingStoryUnit(
            placement.liveWallNormalSnapshot,
            fallback: SIMD3<Float>(0, 0, 1)
        )
        let dot = min(1, max(-1, simd_dot(lhs, rhs)))
        let angleDegrees = acos(dot) * 180 / .pi
        guard centerDelta <= maximumWallCenterDrift,
              angleDegrees <= maximumWallNormalDeltaDegrees else {
            throw TuringStoryHotspotLayoutError.liveWallDrift(placement.wallUUID.uuidString)
        }
    }
}
