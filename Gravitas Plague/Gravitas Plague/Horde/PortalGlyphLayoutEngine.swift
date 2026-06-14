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

        for segment in wallSegments {
            let count = Int.random(
                in: PortalGlyphFXSettings.wallGlyphCountPerSegmentRange,
                using: &rng
            )

            let assets = pickWallAssets(
                count: count,
                library: library,
                rng: &rng
            )

            for asset in assets {
                if let placement = placeWallGlyph(
                    asset: asset,
                    segment: segment,
                    allWallSegments: wallSegments,
                    occupied: occupied,
                    rng: &rng
                ) {
                    placements.append(placement)
                    occupied.append(placement.obb)
                }
            }
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
              directionalOnBordersOnly: true
              generalOnBorderOrOutside: true
              bottomLineDirectionalGlyphs: false
              bottomLineFreeGlyphs: false
              maxDistanceFromBorderFeet: \(PortalGlyphFXSettings.maxDistanceFromBorderFeet)
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

        guard let asset = library.floor.randomElement(using: &rng) else {
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

private extension PortalGlyphLayoutEngine {
    static func pickWallAssets(
        count: Int,
        library: PortalGlyphAssetLibrary,
        rng: inout SeededRNG
    ) -> [PortalGlyphAsset] {
        let directional = library.directional.filter {
            $0.kind == .directional
        }
        let general = library.free.filter {
            $0.kind == .free
        }

        guard !directional.isEmpty || !general.isEmpty else {
            return []
        }

        var out: [PortalGlyphAsset] = []

        for index in 0..<count {
            if index < count / 2,
               let asset = directional.randomElement(using: &rng) {
                out.append(asset)
            } else if let asset = general.randomElement(using: &rng) {
                out.append(asset)
            } else if let asset = directional.randomElement(using: &rng) {
                out.append(asset)
            }
        }

        for asset in out {
            if asset.kind == .floor {
                fatalError(
                    """
                    [PortalGlyphs] FLOOR ASSET SELECTED FOR WALL
                      file: \(asset.fileName)
                    """
                )
            }
        }

        return out
    }
}

private extension PortalGlyphLayoutEngine {
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

        case .floor:
            fatalError("[PortalGlyphs] floor asset sent to wall placer")
        }
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

            guard outerDistance <= PortalGlyphFXSettings.maxDistanceFromBorderMeters else {
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
                    obb: obb
                )
            }
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

        for _ in 0..<PortalGlyphFXSettings.candidateAttemptsPerGlyph {
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
                ) * PortalGlyphFXSettings.maxDistanceFromBorderMeters
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

            guard outerDistance <= PortalGlyphFXSettings.maxDistanceFromBorderMeters else {
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
                    obb: obb
                )
            }
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
            obb: obb
        )
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
