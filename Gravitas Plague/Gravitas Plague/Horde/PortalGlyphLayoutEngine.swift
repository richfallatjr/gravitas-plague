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
        var context = PortalGlyphLayoutContext()
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

        if let circlePlacement = generateSingleCirclePlacement(
            wallSegments: wallSegments,
            library: library,
            occupied: occupied,
            context: &context,
            rng: &rng
        ) {
            placements.append(circlePlacement)
            occupied.append(circlePlacement.obb)
        }

        for segment in wallSegments {
            let count = Int.random(
                in: PortalGlyphFXSettings.wallGlyphCountPerSegmentRange,
                using: &rng
            )

            let assets = pickWallAssets(
                count: count,
                segmentIndex: segment.index,
                library: library,
                context: context,
                rng: &rng
            )

            for asset in assets {
                guard context.canUse(
                    asset,
                    segmentIndex: segment.index
                ) else {
                    if asset.kind == .directional {
                        print(
                            """
                            [PortalGlyphs] skipped directional duplicate on same line
                              file: \(asset.fileName)
                              segment: \(segment.index)
                            """
                        )
                    } else {
                        print(
                            """
                            [PortalGlyphs] skipped glyph due to duplicate rule
                              file: \(asset.fileName)
                              kind: \(asset.kind.rawValue)
                              segment: \(segment.index)
                              directionalDuplicatesAllowedAcrossPortal: true
                              directionalDuplicatesAllowedOnSameLine: false
                              nonDirectionalDuplicatesAllowed: false
                            """
                        )
                    }
                    continue
                }

                if asset.kind == .free,
                   context.freeCount(for: segment.index) >= PortalGlyphFXSettings.maxFreeGlyphsPerSegment {
                    print(
                        """
                        [PortalGlyphs] skipped free glyph
                          file: \(asset.fileName)
                          segment: \(segment.index)
                          reason: free_limit_per_segment
                          limit: \(PortalGlyphFXSettings.maxFreeGlyphsPerSegment)
                        """
                    )
                    continue
                }

                if let placement = placeWallGlyph(
                    asset: asset,
                    segment: segment,
                    allWallSegments: wallSegments,
                    occupied: occupied,
                    rng: &rng
                ) {
                    placements.append(placement)
                    occupied.append(placement.obb)
                    context.markUsed(
                        asset,
                        segmentIndex: segment.index
                    )

                    if asset.kind == .free {
                        context.incrementFreeCount(
                            for: segment.index
                        )
                    }
                }
            }
        }

        validateGlyphDuplicateRules(
            placements: placements,
            context: context
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

        if circleCount > PortalGlyphFXSettings.maxCircleGlyphsPerPortal {
            fatalError(
                """
                [PortalGlyphs] more than one circle glyph generated
                  count: \(circleCount)
                  maxAllowed: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
                """
            )
        }

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
              mode: border_constrained_cloud
              wallSegments: \(wallSegments.count)
              bottomSegmentsSkipped: \(bottomSegments.count)
              placements: \(placements.count)
              directionalCount: \(directionalCount)
              freeCount: \(freeCount)
              circleCount: \(circleCount)
              circleLimit: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
              maxFreePerSegment: \(PortalGlyphFXSettings.maxFreeGlyphsPerSegment)
              directionalOnBordersOnly: true
              generalOnBorderOrOutside: true
              directionalDuplicatesAcrossPortal: allowed
              directionalDuplicatesPerLine: forbidden
              nonDirectionalDuplicatesPerPortal: forbidden
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
    var freeGlyphCountBySegmentIndex: [Int: Int] = [:]
    var circleGlyphCount = 0
    var floorGlyphCount = 0

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

    func freeCount(
        for segmentIndex: Int
    ) -> Int {
        freeGlyphCountBySegmentIndex[segmentIndex] ?? 0
    }

    mutating func incrementFreeCount(
        for segmentIndex: Int
    ) {
        freeGlyphCountBySegmentIndex[segmentIndex, default: 0] += 1
    }
}

private extension PortalGlyphLayoutEngine {
    static func pickWallAssets(
        count: Int,
        segmentIndex: Int,
        library: PortalGlyphAssetLibrary,
        context: PortalGlyphLayoutContext,
        rng: inout SeededRNG
    ) -> [PortalGlyphAsset] {
        let usedDirectionalOnThisLine =
            context.usedDirectionalAssetIDsBySegmentIndex[segmentIndex] ?? []

        let directional = library.directional.filter {
            $0.kind == .directional &&
            !usedDirectionalOnThisLine.contains($0.id)
        }
        let general = library.free.filter {
            $0.kind == .free &&
            !context.usedNonDirectionalAssetIDs.contains($0.id)
        }

        guard !directional.isEmpty || !general.isEmpty else {
            print(
                """
                [PortalGlyphs] no wall assets available for segment
                  segment: \(segmentIndex)
                  directionalUniqueForLine: false
                  generalUniqueForPortal: false
                """
            )
            return []
        }

        var out: [PortalGlyphAsset] = []
        var localDirectionalUsed = Set<String>()
        var localGeneralUsed = Set<String>()

        var freeRemainingForSegment = max(
            0,
            PortalGlyphFXSettings.maxFreeGlyphsPerSegment -
            context.freeCount(for: segmentIndex)
        )

        for index in 0..<count {
            let preferDirectional =
                index < count / 2 ||
                freeRemainingForSegment <= 0 ||
                Float.random(
                    in: 0...1,
                    using: &rng
                ) < PortalGlyphFXSettings.directionalPreference

            if preferDirectional {
                let used =
                    usedDirectionalOnThisLine.union(localDirectionalUsed)

                if let asset = directional.randomElementExcluding(
                    usedIDs: used,
                    rng: &rng
                ) {
                    out.append(asset)
                    localDirectionalUsed.insert(asset.id)
                    continue
                }
            }

            if freeRemainingForSegment > 0 {
                let used =
                    context.usedNonDirectionalAssetIDs.union(localGeneralUsed)

                if let asset = general.randomElementExcluding(
                    usedIDs: used,
                    rng: &rng
                ) {
                    out.append(asset)
                    localGeneralUsed.insert(asset.id)
                    freeRemainingForSegment -= 1
                    continue
                }
            }

            let directionalUsed =
                usedDirectionalOnThisLine.union(localDirectionalUsed)

            if let asset = directional.randomElementExcluding(
                usedIDs: directionalUsed,
                rng: &rng
            ) {
                out.append(asset)
                localDirectionalUsed.insert(asset.id)
                continue
            }
        }

        for asset in out {
            if asset.kind == .floor || asset.kind == .circle {
                fatalError(
                    """
                    [PortalGlyphs] INVALID ASSET SELECTED FOR NORMAL WALL PASS
                      file: \(asset.fileName)
                      kind: \(asset.kind.rawValue)
                    """
                )
            }
        }

        let freePicked = out.filter {
            $0.kind == .free
        }
        .count

        if freePicked > PortalGlyphFXSettings.maxFreeGlyphsPerSegment {
            fatalError(
                """
                [PortalGlyphs] too many free glyphs selected for segment
                  segment: \(segmentIndex)
                  freePicked: \(freePicked)
                  max: \(PortalGlyphFXSettings.maxFreeGlyphsPerSegment)
                """
            )
        }

        let directionalIDs = out
            .filter {
                $0.kind == .directional
            }
            .map(\.id)

        if Set(directionalIDs).count != directionalIDs.count {
            fatalError(
                """
                [PortalGlyphs] duplicate directional selected on same line
                  segment: \(segmentIndex)
                  rule: directional_duplicates_allowed_across_portal_not_per_line
                """
            )
        }

        return out
    }
}

private extension Array where Element == PortalGlyphAsset {
    func randomElementExcluding(
        usedIDs: Set<String>,
        rng: inout SeededRNG
    ) -> PortalGlyphAsset? {
        let available = filter {
            !usedIDs.contains($0.id)
        }

        guard !available.isEmpty else {
            return nil
        }

        return available.randomElement(using: &rng)
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

        guard !wallSegments.isEmpty else {
            return nil
        }

        let preferredSegments = wallSegments.sorted {
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
            context.markUsed(
                strict.asset,
                segmentIndex: nil
            )
            context.circleGlyphCount += 1
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
            context.markUsed(
                fallback.asset,
                segmentIndex: nil
            )
            context.circleGlyphCount += 1
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
                segment.outward * borderRadius +
                segment.outward * Float.random(
                    in: 0...PortalGlyphFXSettings.directionalBorderJitterMeters,
                    using: &rng
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

    static func validateGlyphDuplicateRules(
        placements: [PortalGlyphPlacement],
        context: PortalGlyphLayoutContext
    ) {
        let nonDirectional = placements.filter {
            $0.asset.kind == .free ||
            $0.asset.kind == .circle ||
            $0.asset.kind == .floor
        }

        let nonDirectionalIDs = nonDirectional.map(\.asset.id)

        if Set(nonDirectionalIDs).count != nonDirectionalIDs.count {
            fatalError(
                """
                [PortalGlyphs] duplicate non-directional glyph assets detected
                  rule: free_circle_floor_no_duplicates_per_portal
                """
            )
        }

        let directionalBySegment =
            Dictionary(grouping: placements.filter { $0.asset.kind == .directional }) {
                $0.sourceSegmentIndex ?? -1
            }

        for (segmentIndex, glyphs) in directionalBySegment {
            let ids = glyphs.map(\.asset.id)

            if Set(ids).count != ids.count {
                fatalError(
                    """
                    [PortalGlyphs] duplicate directional glyphs on same segment
                      segment: \(segmentIndex)
                      rule: directional_duplicates_allowed_across_portal_not_per_line
                    """
                )
            }
        }

        let freeBySegment =
            Dictionary(grouping: placements.filter { $0.asset.kind == .free }) {
                $0.sourceSegmentIndex ?? -1
            }

        for (segmentIndex, glyphs) in freeBySegment {
            if glyphs.count > PortalGlyphFXSettings.maxFreeGlyphsPerSegment {
                fatalError(
                    """
                    [PortalGlyphs] too many free glyphs on segment
                      segment: \(segmentIndex)
                      count: \(glyphs.count)
                      max: \(PortalGlyphFXSettings.maxFreeGlyphsPerSegment)
                    """
                )
            }
        }

        if context.circleGlyphCount > PortalGlyphFXSettings.maxCircleGlyphsPerPortal {
            fatalError(
                """
                [PortalGlyphs] too many circle glyphs in context
                  count: \(context.circleGlyphCount)
                  max: \(PortalGlyphFXSettings.maxCircleGlyphsPerPortal)
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
