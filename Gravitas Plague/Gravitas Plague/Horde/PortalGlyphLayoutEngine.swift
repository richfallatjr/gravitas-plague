import Foundation
import simd

@MainActor
enum PortalGlyphLayoutEngine {
    static func generateWallPlacements(
        perimeterPoints: [SIMD3<Float>],
        seed: UInt64,
        library: PortalGlyphAssetLibrary
    ) -> [PortalGlyphPlacement] {
        var rng = SeededRNG(seed: seed)
        let allSegments = buildPerimeterSegments(
            perimeterPoints
        )
        let wallSegments = allSegments.filter {
            $0.kind == .wall
        }
        let bottomSegments = allSegments.filter {
            $0.kind == .bottomFloorOnly
        }

        var placements: [PortalGlyphPlacement] = []
        var occupied: [PortalGlyphOBB] = []
        var context = PortalGlyphLayoutContext()

        if let circlePlacement = generateSingleCirclePlacement(
            wallSegments: wallSegments,
            library: library,
            occupied: occupied,
            context: &context,
            rng: &rng
        ) {
            placements.append(circlePlacement)
            occupied.append(circlePlacement.obb)

            if let segmentIndex = circlePlacement.sourceSegmentIndex {
                context.incrementWallCount(
                    for: segmentIndex
                )
            }

            context.markUsed(
                circlePlacement.asset,
                segmentIndex: circlePlacement.sourceSegmentIndex
            )
            context.circleGlyphCount += 1
        }

        for segment in wallSegments {
            guard context.hasCapacityOnLine(
                segment.index
            ) else {
                continue
            }

            if context.wallCount(for: segment.index) >=
                PortalGlyphFXSettings.minWallGlyphsPerSegmentWhenPossible {
                continue
            }

            guard let placement = placeOneGlyphOnSegment(
                segment: segment,
                allWallSegments: wallSegments,
                library: library,
                occupied: occupied,
                context: context,
                rng: &rng,
                preferDirectional: true
            ) else {
                print(
                    """
                    [PortalGlyphs] line minimum placement skipped
                      segment: \(segment.index)
                      reason: no_valid_candidate
                      hardFail: false
                    """
                )
                continue
            }

            placements.append(placement)
            occupied.append(placement.obb)

            context.incrementWallCount(
                for: segment.index
            )
            context.markUsed(
                placement.asset,
                segmentIndex: placement.sourceSegmentIndex
            )
        }

        for segment in wallSegments {
            while context.hasCapacityOnLine(
                segment.index
            ) {
                guard let placement = placeOneGlyphOnSegment(
                    segment: segment,
                    allWallSegments: wallSegments,
                    library: library,
                    occupied: occupied,
                    context: context,
                    rng: &rng,
                    preferDirectional: false
                ) else {
                    break
                }

                placements.append(placement)
                occupied.append(placement.obb)

                context.incrementWallCount(
                    for: segment.index
                )
                context.markUsed(
                    placement.asset,
                    segmentIndex: placement.sourceSegmentIndex
                )
            }
        }

        validateLineBudgets(
            placements: placements,
            wallSegments: wallSegments
        )
        validateNonDirectionalUniqueness(
            placements: placements
        )

        let directionalCount = placements.filter {
            $0.asset.kind == .directional
        }
        .count
        let freeCount = placements.filter {
            $0.asset.kind == .free
        }
        .count
        let circleCount = placements.filter {
            $0.asset.kind == .circle
        }
        .count
        let lineCounts = wallSegments.map { segment in
            let count = placements.filter {
                $0.sourceSegmentIndex == segment.index
            }
            .count

            return "\(segment.index):\(count)"
        }
        .joined(separator: ", ")

        let minY = perimeterPoints.map(\.y).min() ?? 0

        for placement in placements {
            let nearBottom = abs(placement.center2D.y - minY) < 0.05

            if nearBottom {
                print(
                    """
                    [PortalGlyphs] WARNING wall glyph near bottom line
                      file: \(placement.asset.fileName)
                      kind: \(placement.asset.kind.rawValue)
                      centerY: \(placement.center2D.y)
                      bottomY: \(minY)
                      verifyNotOnBottomSegment: true
                    """
                )
            }
        }

        print(
            """
            [PortalGlyphs] wall placements generated
              mode: segment_budgeted_border_cloud
              wallSegments: \(wallSegments.count)
              bottomSegmentsSkipped: \(bottomSegments.count)
              placements: \(placements.count)
              directionalCount: \(directionalCount)
              freeCount: \(freeCount)
              circleCount: \(circleCount)
              circleLimit: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
              maxPerLine: \(PortalGlyphFXSettings.maxWallGlyphsPerSegment)
              minPerLineAttempted: \(PortalGlyphFXSettings.minWallGlyphsPerSegmentWhenPossible)
              lineCounts: \(lineCounts)
              directionalDuplicatesAcrossPortal: allowed
              directionalDuplicatesPerLine: forbidden
              freeDuplicatesPerPortal: forbidden
              bottomLineDirectionalGlyphs: false
              bottomLineFreeGlyphs: false
              targetMaxDistanceFromBorderFeet: \(PortalGlyphFXSettings.targetMaxDistanceFromBorderFeet)
              softFallbackMaxFeet: \(PortalGlyphFXSettings.fallbackMaxDistanceFromBorderFeet)
              padding: 0
              grid: false
              shelfRows: false
            """
        )

        return placements
    }

    static func generateFloorPlacementsFromBottomLine(
        perimeterPoints: [SIMD3<Float>],
        seed: UInt64,
        library: PortalGlyphAssetLibrary
    ) -> [PortalGlyphPlacement] {
        var rng = SeededRNG(seed: seed ^ 0xF100D)
        var context = PortalGlyphLayoutContext()

        let availableFloorAssets = library.floor.filter {
            $0.kind == .floor &&
            context.canUse(
                $0,
                segmentIndex: nil
            )
        }

        guard let asset = availableFloorAssets.randomElement(using: &rng) else {
            print(
                """
                [PortalGlyphs] no floor glyph assets
                  action: skip_floor_glyph
                """
            )
            return []
        }

        let bottomSegments = buildPerimeterSegments(
            perimeterPoints
        )
        .filter {
            $0.kind == .bottomFloorOnly
        }

        guard !bottomSegments.isEmpty else {
            print(
                """
                [PortalGlyphs] no bottom segment found
                  action: skip_floor_glyph
                """
            )
            return []
        }

        guard let bottom = bottomSegments.randomElement(using: &rng) else {
            print(
                """
                [PortalGlyphs] no bottom segment selected
                  action: skip_floor_glyph
                """
            )
            return []
        }

        guard asset.kind == .floor else {
            fatalError(
                """
                [PortalGlyphs] non-floor asset selected for floor
                  file: \(asset.fileName)
                  kind: \(asset.kind.rawValue)
                """
            )
        }

        let placement = makeSingleFloorGlyphPlacement(
            asset: asset,
            bottomSegment: bottom,
            rng: &rng
        )

        context.markUsed(
            placement.asset,
            segmentIndex: nil
        )
        context.floorGlyphCount += 1

        if context.floorGlyphCount > PortalGlyphFXSettings.floorGlyphCountPerPortal {
            fatalError(
                """
                [PortalGlyphs] more than one floor glyph generated
                  count: \(context.floorGlyphCount)
                  maxAllowed: \(PortalGlyphFXSettings.floorGlyphCountPerPortal)
                """
            )
        }

        print(
            """
            [PortalGlyphs] floor placement generated
              count: \(PortalGlyphFXSettings.floorGlyphCountPerPortal)
              sourceAssets: floor_only
              bottomLineOnly: true
              surface: actual_floor
              padding: 0
              grid: false
            """
        )

        return [placement]
    }
}

enum PortalGlyphSegmentKind: String {
    case wall
    case bottomFloorOnly
}

extension PortalGlyphLayoutEngine {
    static func validateCombinedPortalRules(
        placements: [PortalGlyphPlacement]
    ) {
        validateNonDirectionalUniqueness(
            placements: placements
        )

        let floorCount = placements.filter {
            $0.asset.kind == .floor
        }
        .count

        if floorCount > PortalGlyphFXSettings.floorGlyphCountPerPortal {
            fatalError(
                """
                [PortalGlyphs] too many floor glyphs
                  count: \(floorCount)
                  maxAllowed: \(PortalGlyphFXSettings.floorGlyphCountPerPortal)
                """
            )
        }

        let circleCount = placements.filter {
            $0.asset.kind == .circle
        }
        .count

        if circleCount > PortalGlyphFXSettings.maxCircleGlyphsPerPortal {
            fatalError(
                """
                [PortalGlyphs] too many circle glyphs
                  count: \(circleCount)
                  maxAllowed: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
                """
            )
        }
    }
}

private struct GlyphSegment {
    let index: Int
    let a: SIMD2<Float>
    let b: SIMD2<Float>
    let midpoint: SIMD2<Float>
    let direction: SIMD2<Float>
    let outward: SIMD2<Float>
    let length: Float
    let kind: PortalGlyphSegmentKind
}

private struct PortalGlyphLayoutContext {
    var usedNonDirectionalAssetIDs = Set<String>()
    var usedDirectionalAssetIDsBySegmentIndex: [Int: Set<String>] = [:]
    var wallGlyphCountBySegmentIndex: [Int: Int] = [:]
    var circleGlyphCount = 0
    var floorGlyphCount = 0

    func wallCount(
        for segmentIndex: Int
    ) -> Int {
        wallGlyphCountBySegmentIndex[segmentIndex] ?? 0
    }

    func hasCapacityOnLine(
        _ segmentIndex: Int
    ) -> Bool {
        wallCount(for: segmentIndex) < PortalGlyphFXSettings.maxWallGlyphsPerSegment
    }

    mutating func incrementWallCount(
        for segmentIndex: Int
    ) {
        wallGlyphCountBySegmentIndex[segmentIndex, default: 0] += 1
    }

    func canUse(
        _ asset: PortalGlyphAsset,
        segmentIndex: Int?
    ) -> Bool {
        switch asset.kind {
        case .directional:
            guard let segmentIndex else {
                return false
            }

            let usedOnLine =
                usedDirectionalAssetIDsBySegmentIndex[segmentIndex] ?? []

            return !usedOnLine.contains(asset.id)

        case .free, .circle, .floor:
            return !usedNonDirectionalAssetIDs.contains(asset.id)
        }
    }

    mutating func markUsed(
        _ asset: PortalGlyphAsset,
        segmentIndex: Int?
    ) {
        switch asset.kind {
        case .directional:
            guard let segmentIndex else {
                return
            }

            usedDirectionalAssetIDsBySegmentIndex[segmentIndex, default: []]
                .insert(asset.id)

        case .free, .circle, .floor:
            usedNonDirectionalAssetIDs.insert(asset.id)
        }
    }
}

private extension PortalGlyphLayoutEngine {
    static func placeOneGlyphOnSegment(
        segment: GlyphSegment,
        allWallSegments: [GlyphSegment],
        library: PortalGlyphAssetLibrary,
        occupied: [PortalGlyphOBB],
        context: PortalGlyphLayoutContext,
        rng: inout SeededRNG,
        preferDirectional: Bool
    ) -> PortalGlyphPlacement? {
        guard context.hasCapacityOnLine(
            segment.index
        ) else {
            print(
                """
                [PortalGlyphs] line capacity reached
                  segment: \(segment.index)
                  maxPerLine: \(PortalGlyphFXSettings.maxWallGlyphsPerSegment)
                """
            )
            return nil
        }

        let candidates = candidateAssetsForSegment(
            segmentIndex: segment.index,
            library: library,
            context: context,
            rng: &rng,
            preferDirectional: preferDirectional
        )

        for asset in candidates {
            guard context.canUse(
                asset,
                segmentIndex: segment.index
            ) else {
                continue
            }

            let placement: PortalGlyphPlacement?

            switch asset.kind {
            case .directional:
                placement = placeDirectionalGlyphOnBorder(
                    asset: asset,
                    segment: segment,
                    occupied: occupied,
                    rng: &rng
                )

            case .free:
                placement = placeGeneralGlyphNearBorder(
                    asset: asset,
                    segment: segment,
                    allWallSegments: allWallSegments,
                    occupied: occupied,
                    rng: &rng
                )

            case .circle, .floor:
                fatalError(
                    """
                    [PortalGlyphs] invalid asset in normal segment placement
                      file: \(asset.fileName)
                      kind: \(asset.kind.rawValue)
                    """
                )
            }

            if let placement {
                return placement
            }
        }

        return nil
    }

    static func candidateAssetsForSegment(
        segmentIndex: Int,
        library: PortalGlyphAssetLibrary,
        context: PortalGlyphLayoutContext,
        rng: inout SeededRNG,
        preferDirectional: Bool
    ) -> [PortalGlyphAsset] {
        let usedDirectionalOnThisLine =
            context.usedDirectionalAssetIDsBySegmentIndex[segmentIndex] ?? []

        let directional = library.directional.filter {
            $0.kind == .directional &&
            !usedDirectionalOnThisLine.contains($0.id)
        }

        let free = library.free.filter {
            $0.kind == .free &&
            !context.usedNonDirectionalAssetIDs.contains($0.id)
        }

        var ordered: [PortalGlyphAsset] = []

        if preferDirectional {
            ordered.append(
                contentsOf: shuffled(
                    directional,
                    rng: &rng
                )
            )
            ordered.append(
                contentsOf: shuffled(
                    free,
                    rng: &rng
                )
            )
        } else {
            let useDirectionalFirst =
                Float.random(
                    in: 0...1,
                    using: &rng
                ) < PortalGlyphFXSettings.directionalPreference

            if useDirectionalFirst {
                ordered.append(
                    contentsOf: shuffled(
                        directional,
                        rng: &rng
                    )
                )
                ordered.append(
                    contentsOf: shuffled(
                        free,
                        rng: &rng
                    )
                )
            } else {
                ordered.append(
                    contentsOf: shuffled(
                        free,
                        rng: &rng
                    )
                )
                ordered.append(
                    contentsOf: shuffled(
                        directional,
                        rng: &rng
                    )
                )
            }
        }

        return ordered
    }

    static func shuffled(
        _ input: [PortalGlyphAsset],
        rng: inout SeededRNG
    ) -> [PortalGlyphAsset] {
        var result = input

        guard result.count > 1 else {
            return result
        }

        for index in result.indices.reversed() {
            let swapIndex = Int.random(
                in: 0...index,
                using: &rng
            )

            result.swapAt(
                index,
                swapIndex
            )
        }

        return result
    }
}

private extension PortalGlyphLayoutEngine {
    static func generateSingleCirclePlacement(
        wallSegments: [GlyphSegment],
        library: PortalGlyphAssetLibrary,
        occupied: [PortalGlyphOBB],
        context: inout PortalGlyphLayoutContext,
        rng: inout SeededRNG
    ) -> PortalGlyphPlacement? {
        guard context.circleGlyphCount < PortalGlyphFXSettings.maxCircleGlyphsPerPortal else {
            return nil
        }

        let availableCircles = library.circle.filter {
            $0.kind == .circle &&
            context.canUse(
                $0,
                segmentIndex: nil
            )
        }

        guard !availableCircles.isEmpty else {
            return nil
        }

        guard Float.random(
            in: 0...1,
            using: &rng
        ) <= PortalGlyphFXSettings.circleGlyphProbability else {
            print("[PortalGlyphs] circle glyph skipped by probability")
            return nil
        }

        guard let asset = availableCircles.randomElement(using: &rng) else {
            return nil
        }

        guard asset.kind == .circle else {
            fatalError("[PortalGlyphs] non-circle asset in circle pool")
        }

        let eligibleSegments = wallSegments.filter {
            context.hasCapacityOnLine(
                $0.index
            )
        }

        guard !eligibleSegments.isEmpty else {
            return nil
        }

        let preferredSegments = eligibleSegments.sorted {
            $0.midpoint.y > $1.midpoint.y
        }

        if let strict = placeCircleGlyph(
            asset: asset,
            segments: preferredSegments,
            occupied: occupied,
            rng: &rng,
            maxDistance: PortalGlyphFXSettings.targetMaxDistanceFromBorderMeters,
            attempts: PortalGlyphFXSettings.candidateAttemptsPerGlyph,
            passLabel: "strict_2ft"
        ) {
            return strict
        }

        if let fallback = placeCircleGlyph(
            asset: asset,
            segments: preferredSegments,
            occupied: occupied,
            rng: &rng,
            maxDistance: PortalGlyphFXSettings.fallbackMaxDistanceFromBorderMeters,
            attempts: PortalGlyphFXSettings.fallbackCandidateAttemptsPerGlyph,
            passLabel: "soft_fallback"
        ) {
            return fallback
        }

        print(
            """
            [PortalGlyphs] circle placement skipped
              reason: no_nonoverlap_candidate
              hardFail: false
              maxCirclePerPortal: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
            """
        )

        return nil
    }

    static func placeWallGlyph(
        asset: PortalGlyphAsset,
        segment: GlyphSegment,
        allWallSegments: [GlyphSegment],
        occupied: [PortalGlyphOBB],
        rng: inout SeededRNG
    ) -> PortalGlyphPlacement? {
        guard asset.kind != .floor else {
            fatalError("[PortalGlyphs] floor asset sent to wall placer")
        }

        switch asset.kind {
        case .directional:
            return placeDirectionalGlyphOnBorder(
                asset: asset,
                segment: segment,
                occupied: occupied,
                rng: &rng
            )

        case .free:
            return placeGeneralGlyphNearBorder(
                asset: asset,
                segment: segment,
                allWallSegments: allWallSegments,
                occupied: occupied,
                rng: &rng
            )

        case .circle:
            fatalError("[PortalGlyphs] circle asset sent to normal wall placer")

        case .floor:
            fatalError("[PortalGlyphs] floor asset sent to wall placer")
        }
    }

    static func placeCircleGlyph(
        asset: PortalGlyphAsset,
        segments: [GlyphSegment],
        occupied: [PortalGlyphOBB],
        rng: inout SeededRNG,
        maxDistance: Float,
        attempts: Int,
        passLabel: String
    ) -> PortalGlyphPlacement? {
        let rawSize = asset.physicalSizeMeters()
        let side = max(
            rawSize.x,
            rawSize.y
        )
        let size = SIMD2<Float>(
            side,
            side
        )

        var best: PortalGlyphPlacement?
        var bestScore = Float.greatestFiniteMagnitude

        for _ in 0..<attempts {
            guard let segment = segments.randomElement(using: &rng) else {
                continue
            }

            let along = Float.random(
                in: 0.0...1.0,
                using: &rng
            )

            let edgePoint =
                segment.a +
                (segment.b - segment.a) * along

            let outwardExtra =
                pow(
                    Float.random(
                        in: 0...1,
                        using: &rng
                    ),
                    1.65
                ) * maxDistance

            let center =
                edgePoint +
                segment.outward * (size.y * 0.5 + outwardExtra)

            let angle = Float.random(
                in: 0...(2.0 * .pi),
                using: &rng
            )

            let axisX = normalizeSafe2(
                SIMD2<Float>(
                    cos(angle),
                    sin(angle)
                ),
                fallback: SIMD2<Float>(1, 0)
            )
            let axisY = normalizeSafe2(
                SIMD2<Float>(
                    -sin(angle),
                    cos(angle)
                ),
                fallback: SIMD2<Float>(0, 1)
            )

            let obb = PortalGlyphOBB(
                center: center,
                axisX: axisX,
                axisY: axisY,
                halfSize: size * 0.5
            )

            let overlaps = occupied.contains {
                $0.overlaps(
                    obb,
                    padding: 0
                )
            }

            guard !overlaps else {
                continue
            }

            let distanceToBorder = nearestDistanceToSegments(
                point: center,
                segments: segments
            )
            let nearestBorderPoint = nearestPointOnAnySegment(
                point: center,
                segments: segments
            )

            let outerDistance =
                distanceToBorder +
                projectedRadiusAlong(
                    obb: obb,
                    direction: center - nearestBorderPoint
                )

            guard outerDistance <= maxDistance else {
                continue
            }

            let score =
                distanceToBorder +
                Float.random(
                    in: 0...0.025,
                    using: &rng
                )

            if score < bestScore {
                bestScore = score
                best = PortalGlyphPlacement(
                    asset: asset,
                    surface: .wall,
                    center2D: center,
                    axisX: obb.axisX,
                    axisY: obb.axisY,
                    size: size,
                    rotationRadians: angle,
                    obb: obb,
                    sourceSegmentIndex: segment.index
                )
            }
        }

        if best != nil {
            print(
                """
                [PortalGlyphs] circle placement generated
                  file: \(asset.fileName)
                  pass: \(passLabel)
                  maxDistanceFeet: \(maxDistance / PortalGlyphFXSettings.feetToMeters)
                  circleLimitPerPortal: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
                  surface: wall
                  bottomLine: false
                """
            )
        }

        return best
    }

    static func placeDirectionalGlyphOnBorder(
        asset: PortalGlyphAsset,
        segment: GlyphSegment,
        occupied: [PortalGlyphOBB],
        rng: inout SeededRNG
    ) -> PortalGlyphPlacement? {
        let size = asset.physicalSizeMeters()
        var best: PortalGlyphPlacement?
        var bestScore = Float.greatestFiniteMagnitude

        for _ in 0..<PortalGlyphFXSettings.candidateAttemptsPerGlyph {
            let along = Float.random(
                in: 0.0...1.0,
                using: &rng
            )

            let edgePoint =
                segment.a +
                (segment.b - segment.a) * along

            let angleJitter = Float.random(
                in: (-3.0 * .pi / 180.0)...(3.0 * .pi / 180.0),
                using: &rng
            )

            // Directional art is authored vertically: local Y follows the portal border.
            let angle =
                atan2(
                    -segment.direction.x,
                    segment.direction.y
                ) +
                angleJitter

            let axisX = normalizeSafe2(
                SIMD2<Float>(
                    cos(angle),
                    sin(angle)
                ),
                fallback: segment.outward
            )

            let axisY = normalizeSafe2(
                SIMD2<Float>(
                    -sin(angle),
                    cos(angle)
                ),
                fallback: segment.direction
            )

            let provisionalOBB = PortalGlyphOBB(
                center: edgePoint,
                axisX: axisX,
                axisY: axisY,
                halfSize: size * 0.5
            )

            let borderRadius = projectedRadiusAlong(
                obb: provisionalOBB,
                direction: segment.outward
            )

            let center =
                edgePoint +
                segment.outward * borderRadius

            let obb = PortalGlyphOBB(
                center: center,
                axisX: axisX,
                axisY: axisY,
                halfSize: size * 0.5
            )

            let overlaps = occupied.contains {
                $0.overlaps(
                    obb,
                    padding: 0
                )
            }

            guard !overlaps else {
                continue
            }

            let distanceFromBorder = distanceFromPointToSegment(
                point: center,
                a: segment.a,
                b: segment.b
            )

            let outerDistance =
                distanceFromBorder +
                projectedRadiusAlong(
                    obb: obb,
                    direction: segment.outward
                )

            guard outerDistance <= PortalGlyphFXSettings.targetMaxDistanceFromBorderMeters else {
                continue
            }

            let score = distanceFromBorder

            if score < bestScore {
                bestScore = score
                best = PortalGlyphPlacement(
                    asset: asset,
                    surface: .wall,
                    center2D: center,
                    axisX: axisX,
                    axisY: axisY,
                    size: size,
                    rotationRadians: angle,
                    obb: obb,
                    sourceSegmentIndex: segment.index
                )
            }
        }

        if best != nil {
            print(
                """
                [PortalGlyphs] directional placement generated
                  file: \(asset.fileName)
                  borderOnly: true
                  spreadFeet: 0
                """
            )
        }

        return best
    }

    static func placeGeneralGlyphNearBorder(
        asset: PortalGlyphAsset,
        segment: GlyphSegment,
        allWallSegments: [GlyphSegment],
        occupied: [PortalGlyphOBB],
        rng: inout SeededRNG
    ) -> PortalGlyphPlacement? {
        if let strict = placeGeneralGlyphNearBorderPass(
            asset: asset,
            segment: segment,
            allWallSegments: allWallSegments,
            occupied: occupied,
            rng: &rng,
            maxDistance: PortalGlyphFXSettings.targetMaxDistanceFromBorderMeters,
            attempts: PortalGlyphFXSettings.candidateAttemptsPerGlyph,
            passLabel: "strict_2ft"
        ) {
            return strict
        }

        if let fallback = placeGeneralGlyphNearBorderPass(
            asset: asset,
            segment: segment,
            allWallSegments: allWallSegments,
            occupied: occupied,
            rng: &rng,
            maxDistance: PortalGlyphFXSettings.fallbackMaxDistanceFromBorderMeters,
            attempts: PortalGlyphFXSettings.fallbackCandidateAttemptsPerGlyph,
            passLabel: "soft_fallback"
        ) {
            return fallback
        }

        print(
            """
            [PortalGlyphs] general placement skipped
              file: \(asset.fileName)
              reason: no_nonoverlap_candidate
              hardFail: false
            """
        )

        return nil
    }

    static func placeGeneralGlyphNearBorderPass(
        asset: PortalGlyphAsset,
        segment: GlyphSegment,
        allWallSegments: [GlyphSegment],
        occupied: [PortalGlyphOBB],
        rng: inout SeededRNG,
        maxDistance: Float,
        attempts: Int,
        passLabel: String
    ) -> PortalGlyphPlacement? {
        let rawSize = asset.physicalSizeMeters()
        let side = max(
            rawSize.x,
            rawSize.y
        )
        let size = SIMD2<Float>(
            side,
            side
        )

        var best: PortalGlyphPlacement?
        var bestScore = Float.greatestFiniteMagnitude

        for _ in 0..<attempts {
            let along = Float.random(
                in: 0.0...1.0,
                using: &rng
            )

            let edgePoint =
                segment.a +
                (segment.b - segment.a) * along

            let onBorder =
                Float.random(
                    in: 0...1,
                    using: &rng
                ) < PortalGlyphFXSettings.generalBorderProbability

            let outwardExtra: Float

            if onBorder {
                outwardExtra = 0
            } else {
                outwardExtra = pow(
                    Float.random(
                        in: 0...1,
                        using: &rng
                    ),
                    1.85
                ) * maxDistance
            }

            let tangentJitter =
                segment.direction *
                Float.random(
                    in: -size.x * 0.35...size.x * 0.35,
                    using: &rng
                )

            let center =
                edgePoint +
                segment.outward * (size.y * 0.5 + outwardExtra) +
                tangentJitter

            let angle = Float.random(
                in: 0...(2.0 * .pi),
                using: &rng
            )

            let axisX = normalizeSafe2(
                SIMD2<Float>(
                    cos(angle),
                    sin(angle)
                ),
                fallback: SIMD2<Float>(1, 0)
            )

            let axisY = normalizeSafe2(
                SIMD2<Float>(
                    -sin(angle),
                    cos(angle)
                ),
                fallback: SIMD2<Float>(0, 1)
            )

            let obb = PortalGlyphOBB(
                center: center,
                axisX: axisX,
                axisY: axisY,
                halfSize: size * 0.5
            )

            let overlaps = occupied.contains {
                $0.overlaps(
                    obb,
                    padding: 0
                )
            }

            guard !overlaps else {
                continue
            }

            let distanceToNearestBorder = nearestDistanceToSegments(
                point: center,
                segments: allWallSegments
            )

            let outerDistance =
                distanceToNearestBorder +
                projectedRadiusAlong(
                    obb: obb,
                    direction: center - nearestPointOnAnySegment(
                        point: center,
                        segments: allWallSegments
                    )
                )

            guard outerDistance <= maxDistance else {
                continue
            }

            let score =
                distanceToNearestBorder +
                Float.random(
                    in: 0...0.03,
                    using: &rng
                )

            if score < bestScore {
                bestScore = score
                best = PortalGlyphPlacement(
                    asset: asset,
                    surface: .wall,
                    center2D: center,
                    axisX: obb.axisX,
                    axisY: obb.axisY,
                    size: size,
                    rotationRadians: angle,
                    obb: obb,
                    sourceSegmentIndex: segment.index
                )
            }
        }

        if best != nil {
            print(
                """
                [PortalGlyphs] general placement generated
                  file: \(asset.fileName)
                  pass: \(passLabel)
                  maxDistanceFeet: \(maxDistance / PortalGlyphFXSettings.feetToMeters)
                  hardFail: false
                """
            )
        }

        return best
    }

    static func makeSingleFloorGlyphPlacement(
        asset: PortalGlyphAsset,
        bottomSegment: GlyphSegment,
        rng: inout SeededRNG
    ) -> PortalGlyphPlacement {
        guard asset.kind == .floor else {
            fatalError(
                """
                [PortalGlyphs] non-floor asset sent to single floor placement
                  file: \(asset.fileName)
                """
            )
        }

        let size = asset.physicalSizeMeters()
        let along = Float.random(
            in: 0.28...0.72,
            using: &rng
        )

        let edgePoint =
            bottomSegment.a +
            (bottomSegment.b - bottomSegment.a) * along

        let center = SIMD2<Float>(
            edgePoint.x,
            size.y * 0.5
        )

        let angle = Float.random(
            in: (-18.0 * .pi / 180.0)...(18.0 * .pi / 180.0),
            using: &rng
        )

        let axisX = normalizeSafe2(
            SIMD2<Float>(
                cos(angle),
                sin(angle)
            ),
            fallback: SIMD2<Float>(1, 0)
        )

        let axisY = normalizeSafe2(
            SIMD2<Float>(
                -sin(angle),
                cos(angle)
            ),
            fallback: SIMD2<Float>(0, 1)
        )

        let obb = PortalGlyphOBB(
            center: center,
            axisX: axisX,
            axisY: axisY,
            halfSize: size * 0.5
        )

        return PortalGlyphPlacement(
            asset: asset,
            surface: .floor,
            center2D: center,
            axisX: obb.axisX,
            axisY: obb.axisY,
            size: size,
            rotationRadians: angle,
            obb: obb,
            sourceSegmentIndex: bottomSegment.index
        )
    }

    static func validateLineBudgets(
        placements: [PortalGlyphPlacement],
        wallSegments: [GlyphSegment]
    ) {
        let wallSegmentIDs = Set(
            wallSegments.map(\.index)
        )

        let grouped = Dictionary(
            grouping: placements.filter {
                $0.surface == .wall &&
                $0.sourceSegmentIndex != nil
            },
            by: {
                $0.sourceSegmentIndex!
            }
        )

        for (segmentIndex, glyphs) in grouped {
            guard wallSegmentIDs.contains(
                segmentIndex
            ) else {
                continue
            }

            if glyphs.count > PortalGlyphFXSettings.maxWallGlyphsPerSegment {
                fatalError(
                    """
                    [PortalGlyphs] TOO MANY GLYPHS ON ONE LINE
                      segment: \(segmentIndex)
                      count: \(glyphs.count)
                      maxAllowed: \(PortalGlyphFXSettings.maxWallGlyphsPerSegment)
                      files: \(glyphs.map { $0.asset.fileName }.joined(separator: ", "))
                    """
                )
            }

            let directionalIDs = glyphs
                .filter {
                    $0.asset.kind == .directional
                }
                .map(\.asset.id)

            if Set(directionalIDs).count != directionalIDs.count {
                fatalError(
                    """
                    [PortalGlyphs] duplicate directional glyph on same line
                      segment: \(segmentIndex)
                      files: \(glyphs.map { $0.asset.fileName }.joined(separator: ", "))
                    """
                )
            }
        }

        for segment in wallSegments {
            let count = grouped[segment.index]?.count ?? 0

            if count == 0 {
                print(
                    """
                    [PortalGlyphs] WARNING no glyphs placed on non-floor line
                      segment: \(segment.index)
                      hardFail: false
                    """
                )
            }
        }
    }

    static func validateNonDirectionalUniqueness(
        placements: [PortalGlyphPlacement]
    ) {
        let nonDirectional = placements.filter {
            $0.asset.kind == .free ||
            $0.asset.kind == .circle ||
            $0.asset.kind == .floor
        }

        let ids = nonDirectional.map(\.asset.id)

        if Set(ids).count != ids.count {
            fatalError(
                """
                [PortalGlyphs] duplicate non-directional glyph detected
                  files: \(nonDirectional.map { $0.asset.fileName }.joined(separator: ", "))
                  rule: free_circle_floor_unique_per_portal
                """
            )
        }
    }

    static func nearestDistanceToSegments(
        point: SIMD2<Float>,
        segments: [GlyphSegment]
    ) -> Float {
        segments.map {
            distanceFromPointToSegment(
                point: point,
                a: $0.a,
                b: $0.b
            )
        }
        .min() ?? Float.greatestFiniteMagnitude
    }

    static func nearestPointOnAnySegment(
        point: SIMD2<Float>,
        segments: [GlyphSegment]
    ) -> SIMD2<Float> {
        var bestPoint = point
        var bestDistance = Float.greatestFiniteMagnitude

        for segment in segments {
            let candidate = nearestPointOnSegment(
                point: point,
                a: segment.a,
                b: segment.b
            )

            let distance = simd_length(
                point - candidate
            )

            if distance < bestDistance {
                bestDistance = distance
                bestPoint = candidate
            }
        }

        return bestPoint
    }

    static func distanceFromPointToSegment(
        point: SIMD2<Float>,
        a: SIMD2<Float>,
        b: SIMD2<Float>
    ) -> Float {
        simd_length(
            point - nearestPointOnSegment(
                point: point,
                a: a,
                b: b
            )
        )
    }

    static func projectedRadiusAlong(
        obb: PortalGlyphOBB,
        direction: SIMD2<Float>
    ) -> Float {
        let normalizedDirection = normalizeSafe2(
            direction,
            fallback: SIMD2<Float>(0, 1)
        )

        return abs(
            simd_dot(
                obb.axisX,
                normalizedDirection
            )
        ) * obb.halfSize.x +
        abs(
            simd_dot(
                obb.axisY,
                normalizedDirection
            )
        ) * obb.halfSize.y
    }
}

private extension PortalGlyphLayoutEngine {
    static func buildPerimeterSegments(
        _ points3D: [SIMD3<Float>]
    ) -> [GlyphSegment] {
        guard points3D.count >= 2 else {
            return []
        }

        let points = points3D.map {
            SIMD2<Float>(
                $0.x,
                $0.y
            )
        }

        let center = apertureCenter(
            points3D
        )
        let minY = points.map(\.y).min() ?? 0
        let bottomEpsilon: Float = 0.012

        var out: [GlyphSegment] = []

        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let delta = b - a
            let length = simd_length(delta)

            guard length > 0.001 else {
                continue
            }

            let direction = delta / length
            let midpoint = (a + b) * 0.5
            var perpendicular = SIMD2<Float>(
                -direction.y,
                direction.x
            )

            let toMid = midpoint - SIMD2<Float>(
                center.x,
                center.y
            )

            if simd_dot(
                perpendicular,
                toMid
            ) < 0 {
                perpendicular = -perpendicular
            }

            let isBottom =
                abs(a.y - minY) <= bottomEpsilon &&
                abs(b.y - minY) <= bottomEpsilon

            out.append(
                GlyphSegment(
                    index: index,
                    a: a,
                    b: b,
                    midpoint: midpoint,
                    direction: normalizeSafe2(
                        direction,
                        fallback: SIMD2<Float>(1, 0)
                    ),
                    outward: normalizeSafe2(
                        perpendicular,
                        fallback: SIMD2<Float>(0, 1)
                    ),
                    length: length,
                    kind: isBottom ? .bottomFloorOnly : .wall
                )
            )
        }

        print(
            """
            [PortalGlyphs] perimeter segments classified
              total: \(out.count)
              wall: \(out.filter { $0.kind == .wall }.count)
              bottomFloorOnly: \(out.filter { $0.kind == .bottomFloorOnly }.count)
              bottomRule: floor_assets_only
            """
        )

        return out
    }

    static func apertureCenter(
        _ points: [SIMD3<Float>]
    ) -> SIMD3<Float> {
        guard !points.isEmpty else {
            return .zero
        }

        let sum = points.reduce(SIMD3<Float>.zero) {
            $0 + $1
        }

        return sum / Float(points.count)
    }

    static func nearestPointOnSegment(
        point: SIMD2<Float>,
        a: SIMD2<Float>,
        b: SIMD2<Float>
    ) -> SIMD2<Float> {
        let ab = b - a
        let denom = max(
            simd_dot(ab, ab),
            0.00001
        )

        let t = max(
            0,
            min(
                1,
                simd_dot(
                    point - a,
                    ab
                ) / denom
            )
        )

        return a + ab * t
    }
}
