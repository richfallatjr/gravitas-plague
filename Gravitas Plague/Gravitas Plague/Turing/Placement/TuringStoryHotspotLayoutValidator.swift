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
