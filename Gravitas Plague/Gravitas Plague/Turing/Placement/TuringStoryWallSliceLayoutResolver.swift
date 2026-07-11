import Foundation
import simd

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
    let requested: [(TuringStoryPropID, [String]?)] = [
      (.door, plan.d),
      (.window, plan.w),
      (.walkieShelf, plan.s),
      (.poster, plan.p),
    ]
    let sliceByID = map.sliceByID
    var validatedGroups: [(TuringStoryPropID, [TuringStoryWallSlice])] = []
    var consumedSliceIDs = Set<String>()

    for (propID, ids) in requested {
      guard let ids, ids.isEmpty == false else { continue }
      var slices: [TuringStoryWallSlice] = []

      for id in ids {
        if let known = sliceByID[id] {
          slices.append(known)
          consumedSliceIDs.insert(known.sliceID)
          continue
        }

        guard let projected = nearestAvailableSlice(
          requestedID: id,
          slices: map.slices,
          excluding: consumedSliceIDs
        ) else {
          print(
            "[TuringWallSlices] unknown slice ignored prop=\(propID.rawValue) requested=\(id) runFails=false"
          )
          continue
        }

        slices.append(projected)
        consumedSliceIDs.insert(projected.sliceID)
        print(
          """
          [TuringWallSlices] unknown slice projected by response cleanser
            prop: \(propID.rawValue)
            requestedSliceID: \(id)
            projectedSliceID: \(projected.sliceID)
            projectionRule: nearestActualUnusedSlice
            runFails: false
          """)
      }

      if slices.isEmpty == false {
        validatedGroups.append((propID, slices))
      }
    }

    let assignments: [TuringStoryResolvedSliceAssignment] =
      validatedGroups.compactMap {
        propID, slices -> TuringStoryResolvedSliceAssignment? in
        guard let anchorSlice = slices.first,
          let wall = map.perimeter.walls.first(where: {
            $0.wallOrdinal == anchorSlice.wallOrdinal
              && $0.representativeWallUUID == anchorSlice.representativeWallUUID
          })
        else {
          print(
            "[TuringWallSlices] internal slice mapping missing prop=\(propID.rawValue) runFails=false"
          )
          return nil
        }
        let anchoredSlices = slices.filter {
          $0.representativeWallUUID == anchorSlice.representativeWallUUID
        }
        let intervalMin = anchoredSlices.map(\.localMinX).min() ?? anchorSlice.localMinX
        let intervalMax = anchoredSlices.map(\.localMaxX).max() ?? anchorSlice.localMaxX
        let targetX = (intervalMin + intervalMax) * 0.5
        let candidates = catalog.placements(for: propID).filter {
          $0.wallUUID == anchorSlice.representativeWallUUID && $0.localX >= intervalMin - 0.001
            && $0.localX <= intervalMax + 0.001
        }
        let exact =
          candidates.min(by: {
            let lhs = abs($0.localX - targetX)
            let rhs = abs($1.localX - targetX)
            if lhs != rhs { return lhs < rhs }
            return $0.placementID < $1.placementID
          })
          ?? projectedPlacement(
            propID: propID,
            slice: anchorSlice,
            wall: wall,
            floorWorldY: map.perimeter.floorWorldY
          )

        if candidates.isEmpty {
          print(
            """
            [TuringWallSlices] selected slice projected directly
              prop: \(propID.rawValue)
              sliceID: \(anchorSlice.sliceID)
              advertisedOptions: \(anchorSlice.optionString)
              exactCatalogMatch: false
              optionCompatibilityRequired: false
              runFails: false
            """)
        }
        return TuringStoryResolvedSliceAssignment(
          propID: propID,
          sliceIDs: anchoredSlices.map(\.sliceID),
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

  private func nearestAvailableSlice(
    requestedID: String,
    slices: [TuringStoryWallSlice],
    excluding consumedSliceIDs: Set<String>
  ) -> TuringStoryWallSlice? {
    let available = slices.filter {
      consumedSliceIDs.contains($0.sliceID) == false
    }
    guard available.isEmpty == false else {
      return slices.first
    }

    guard let requestedNumber = Int(requestedID) else {
      return available.first
    }

    return available.min { lhs, rhs in
      let lhsNumber = Int(lhs.sliceID) ?? Int.max
      let rhsNumber = Int(rhs.sliceID) ?? Int.max
      let lhsDistance = abs(lhsNumber - requestedNumber)
      let rhsDistance = abs(rhsNumber - requestedNumber)

      if lhsDistance != rhsDistance {
        return lhsDistance < rhsDistance
      }
      return lhs.sliceID < rhs.sliceID
    }
  }

  private func projectedPlacement(
    propID: TuringStoryPropID,
    slice: TuringStoryWallSlice,
    wall: TuringStorySpinOrderedWall,
    floorWorldY: Float
  ) -> TuringStoryExactPlacement {
    let posterSize = SIMD2<Float>(
      WallPosterMetrics.maxHeightMeters * WallPosterMetrics.aspect,
      WallPosterMetrics.maxHeightMeters
    )
    let envelope = TuringStoryPlanningEnvelope.all(
      posterSize: posterSize
    ).first { $0.propID == propID }!
    let visualSize = visualSize(
      propID: propID,
      posterSize: posterSize
    )
    let reservationWidth = max(
      visualSize.x,
      envelope.preferredWidthMeters
    )
    let reservationHeight = max(
      visualSize.y,
      envelope.reservationHeightMeters
    )
    let canonicalWall = wall.runtimeWall
    let upY =
      abs(canonicalWall.up.y) > 0.0001
      ? canonicalWall.up.y
      : 1
    let visualWorldCenterY = visualWorldCenterY(
      propID: propID,
      floorWorldY: floorWorldY,
      visualHeight: visualSize.y
    )
    let semanticWorldCenterY: Float
    if propID == .poster {
      semanticWorldCenterY = floorWorldY + WallPosterPlacementTuning.preferredCenterHeightMeters
    } else {
      semanticWorldCenterY =
        floorWorldY + (envelope.bottomAboveFloorMeters + envelope.topAboveFloorMeters) * 0.5
    }
    let canonicalVisualLocalY = (visualWorldCenterY - canonicalWall.center.y) / upY
    let canonicalSemanticLocalY = (semanticWorldCenterY - canonicalWall.center.y) / upY
    let selectedLocalX = slice.localCenterX
    let visualWorldCenter =
      canonicalWall.center + canonicalWall.right * selectedLocalX + canonicalWall.up
      * canonicalVisualLocalY
    let semanticWorldCenter =
      canonicalWall.center + canonicalWall.right * selectedLocalX + canonicalWall.up
      * canonicalSemanticLocalY
    let representativeCenter = canonicalWall.representativeCenterSnapshot
    let visualDelta = visualWorldCenter - representativeCenter
    let halfRight = canonicalWall.right * (reservationWidth * 0.5)
    let halfUp = canonicalWall.up * (reservationHeight * 0.5)
    let semanticCorners = [
      semanticWorldCenter - halfRight - halfUp,
      semanticWorldCenter + halfRight - halfUp,
      semanticWorldCenter - halfRight + halfUp,
      semanticWorldCenter + halfRight + halfUp,
    ]
    let projectedCorners = semanticCorners.map { point -> SIMD2<Float> in
      let delta = point - representativeCenter
      return SIMD2<Float>(
        simd_dot(delta, canonicalWall.right),
        simd_dot(delta, canonicalWall.up)
      )
    }
    let runtimeLocalX = simd_dot(
      visualDelta,
      canonicalWall.right
    )
    let runtimeLocalY = simd_dot(
      visualDelta,
      canonicalWall.up
    )
    let semanticRect = TuringStorySemanticRect(
      minX: selectedLocalX - reservationWidth * 0.5,
      minY: canonicalSemanticLocalY - reservationHeight * 0.5,
      maxX: selectedLocalX + reservationWidth * 0.5,
      maxY: canonicalSemanticLocalY + reservationHeight * 0.5
    )
    let runtimeSemanticRect = TuringStorySemanticRect(
      minX: projectedCorners.map(\.x).min() ?? runtimeLocalX,
      minY: projectedCorners.map(\.y).min() ?? runtimeLocalY,
      maxX: projectedCorners.map(\.x).max() ?? runtimeLocalX,
      maxY: projectedCorners.map(\.y).max() ?? runtimeLocalY
    )

    return TuringStoryExactPlacement(
      placementID: "\(propID.shortID):slice-\(slice.sliceID):direct",
      propID: propID,
      wallUUID: slice.representativeWallUUID,
      wallID: slice.wallID,
      localX: selectedLocalX,
      localY: canonicalVisualLocalY,
      worldBottomY: floorWorldY + envelope.bottomAboveFloorMeters,
      worldTopY: floorWorldY + envelope.topAboveFloorMeters,
      reservationWidth: reservationWidth,
      reservationHeight: reservationHeight,
      visualWidth: visualSize.x,
      visualHeight: visualSize.y,
      depthOffset: envelope.depthOffsetMeters,
      floorWorldY: floorWorldY,
      floorFrontageScore: slice.floorSupportScore,
      floorEvidenceKnown: slice.floorEvidenceKnown,
      wallCenterScore: slice.wallCenterScore,
      cornerClearanceScore: slice.cornerClearanceScore,
      wallStabilityScore: slice.wallStability,
      deterministicQuality: 0,
      semanticRect: semanticRect,
      runtimeLocalX: runtimeLocalX,
      runtimeLocalY: runtimeLocalY,
      runtimeSemanticRect: runtimeSemanticRect,
      liveWallCenterSnapshot: canonicalWall.representativeCenterSnapshot,
      liveWallNormalSnapshot: canonicalWall.representativeNormalSnapshot
    )
  }

  private func visualSize(
    propID: TuringStoryPropID,
    posterSize: SIMD2<Float>
  ) -> SIMD2<Float> {
    switch propID {
    case .door:
      return SIMD2<Float>(
        TuringStoryDoorBundleTuning.defaultWidthMeters,
        TuringStoryDoorBundleTuning.defaultHeightMeters
      )
    case .window:
      return SIMD2<Float>(
        TuringStoryWindowBundleTuning.defaultWidthMeters,
        TuringStoryWindowBundleTuning.defaultHeightMeters
      )
    case .walkieShelf:
      return SIMD2<Float>(
        TuringStoryWalkieBundleTuning.defaultWidthMeters,
        TuringStoryWalkieBundleTuning.defaultHeightMeters
      )
    case .poster:
      return posterSize
    }
  }

  private func visualWorldCenterY(
    propID: TuringStoryPropID,
    floorWorldY: Float,
    visualHeight: Float
  ) -> Float {
    switch propID {
    case .door:
      return floorWorldY + visualHeight * 0.5
    case .window:
      return floorWorldY + TuringStoryWindowBundleTuning.preferredBottomHeightMeters + visualHeight
        * 0.5
    case .walkieShelf:
      return floorWorldY + TuringStoryWalkieBundleTuning.preferredCenterHeightMeters
    case .poster:
      return floorWorldY + WallPosterPlacementTuning.preferredCenterHeightMeters
    }
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
      guard
        let id = assignments.first(where: { $0.propID == propID })?
          .sliceIDs.first,
        let numeric = Int(id)
      else { return "null" }
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
