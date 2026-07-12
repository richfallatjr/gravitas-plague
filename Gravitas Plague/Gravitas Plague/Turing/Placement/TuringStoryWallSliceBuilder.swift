import Foundation
import simd

struct TuringStoryWallSliceBuilder: Sendable {
    static let targetSliceWidthMeters: Float = 0.9144
    static let maximumSlicesPerWall = 10

    func build(
        perimeter: TuringStorySpinOrderedPerimeter,
        catalog: TuringStoryExactPlacementCatalog
    ) throws -> TuringStoryWallSliceMap {
        var slices: [TuringStoryWallSlice] = []
        for wall in perimeter.walls {
            let approximateCount = Int(
                (wall.widthMeters / Self.targetSliceWidthMeters).rounded()
            )
            let sliceCount = min(
                Self.maximumSlicesPerWall,
                max(1, approximateCount)
            )
            let actualSliceWidth = wall.widthMeters / Float(sliceCount)
            let startLocalX = localX(
                worldXZ: wall.startXZ,
                wall: wall.runtimeWall
            )
            let endLocalX = localX(
                worldXZ: wall.endXZ,
                wall: wall.runtimeWall
            )

            for localIndex in 0..<sliceCount {
                let startU = Float(localIndex) / Float(sliceCount)
                let endU = Float(localIndex + 1) / Float(sliceCount)
                let firstX = startLocalX + (endLocalX - startLocalX) * startU
                let secondX = startLocalX + (endLocalX - startLocalX) * endU
                let localMinX = min(firstX, secondX)
                let localMaxX = max(firstX, secondX)
                let localCenterX = (localMinX + localMaxX) * 0.5
                let numericSliceID = wall.wallOrdinal * 10 + localIndex
                let floorCandidates = placements(
                    propID: .door,
                    wall: wall,
                    interval: localMinX...localMaxX,
                    catalog: catalog
                )
                let floorSupport = floorCandidates.map(\.floorFrontageScore).max()
                    ?? wall.aggregateFloorFrontageScore
                let floorKnown = floorCandidates.contains(where: \.floorEvidenceKnown)
                let halfWidth = max(0.001, wall.widthMeters * 0.5)
                let wallCenterScore = max(
                    0,
                    1 - abs(localCenterX) / halfWidth
                )
                let cornerClearance = min(
                    localMinX - (-halfWidth),
                    halfWidth - localMaxX
                )
                let cornerScore = min(1, max(0, cornerClearance / 0.90))
                var options: Set<TuringStoryWallSliceOption> = []

                if hasPlacement(
                    propID: .window,
                    wall: wall,
                    interval: localMinX...localMaxX,
                    catalog: catalog
                ) {
                    options.insert(.windowOne)
                }
                if hasPlacement(
                    propID: .walkieShelf,
                    wall: wall,
                    interval: localMinX...localMaxX,
                    catalog: catalog
                ) {
                    options.insert(.shelfOne)
                }
                if hasPlacement(
                    propID: .poster,
                    wall: wall,
                    interval: localMinX...localMaxX,
                    catalog: catalog
                ) {
                    options.insert(.posterOne)
                }

                if localIndex + 1 < sliceCount {
                    let nextEndU = Float(localIndex + 2) / Float(sliceCount)
                    let nextEndX = startLocalX + (endLocalX - startLocalX) * nextEndU
                    let spanMin = min(firstX, nextEndX)
                    let spanMax = max(firstX, nextEndX)
                    if hasPlacement(
                        propID: .door,
                        wall: wall,
                        interval: spanMin...spanMax,
                        catalog: catalog,
                        requireFloorSupport: true
                    ) {
                        options.insert(.doorTwo)
                    }
                    if hasPlacement(
                        propID: .window,
                        wall: wall,
                        interval: spanMin...spanMax,
                        catalog: catalog
                    ) {
                        options.insert(.windowTwo)
                    }
                }

                slices.append(
                    TuringStoryWallSlice(
                        sliceID: String(numericSliceID),
                        numericSliceID: numericSliceID,
                        wallOrdinal: wall.wallOrdinal,
                        wallID: wall.publicWallID,
                        sourceWallID: wall.sourceWallID,
                        representativeWallUUID: wall.representativeWallUUID,
                        localSliceIndex: localIndex,
                        sliceCountOnWall: sliceCount,
                        localMinX: localMinX,
                        localMaxX: localMaxX,
                        localCenterX: localCenterX,
                        widthMeters: actualSliceWidth,
                        isWallStartEdge: localIndex == 0,
                        isWallEndEdge: localIndex == sliceCount - 1,
                        floorSupportScore: floorSupport,
                        floorEvidenceKnown: floorKnown,
                        wallCenterScore: wallCenterScore,
                        cornerClearanceScore: cornerScore,
                        wallStability: wall.stability,
                        options: options
                    )
                )
            }
            print(
                "[TuringWallSlices] wall sliced wallOrdinal=\(wall.wallOrdinal) sliceCount=\(sliceCount) actualSliceWidth=\(actualSliceWidth)"
            )
        }
        guard slices.isEmpty == false else {
            throw TuringStoryWallSliceError.noSlices
        }
        return TuringStoryWallSliceMap(perimeter: perimeter, slices: slices)
    }

    private func hasPlacement(
        propID: TuringStoryPropID,
        wall: TuringStorySpinOrderedWall,
        interval: ClosedRange<Float>,
        catalog: TuringStoryExactPlacementCatalog,
        requireFloorSupport: Bool = false
    ) -> Bool {
        placements(
            propID: propID,
            wall: wall,
            interval: interval,
            catalog: catalog
        ).contains {
            requireFloorSupport == false ||
                ($0.floorEvidenceKnown && $0.floorFrontageScore > 0)
        }
    }

    private func placements(
        propID: TuringStoryPropID,
        wall: TuringStorySpinOrderedWall,
        interval: ClosedRange<Float>,
        catalog: TuringStoryExactPlacementCatalog
    ) -> [TuringStoryExactPlacement] {
        catalog.placements(for: propID).filter {
            $0.wallUUID == wall.representativeWallUUID &&
                interval.contains($0.localX)
        }
    }

    private func localX(
        worldXZ: SIMD2<Float>,
        wall: TuringStoryCanonicalWall
    ) -> Float {
        let point = SIMD3<Float>(worldXZ.x, wall.center.y, worldXZ.y)
        return simd_dot(point - wall.center, wall.right)
    }
}
