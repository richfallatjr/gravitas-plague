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
        let segments = buildPerimeterSegments(
            perimeterPoints
        )
        let center = apertureCenter(
            perimeterPoints
        )

        var placements: [PortalGlyphPlacement] = []
        var occupied: [PortalGlyphOBB] = []

        for segment in segments {
            let count = Int.random(
                in: PortalGlyphFXSettings.glyphCountPerSegmentRange,
                using: &rng
            )

            for index in 0..<count {
                let useDirectional =
                    !library.directional.isEmpty &&
                    Float.random(in: 0...1, using: &rng) < PortalGlyphFXSettings.directionalPreference

                let assetPool: [PortalGlyphAsset]

                if useDirectional {
                    assetPool = library.directional
                } else if !library.free.isEmpty {
                    assetPool = library.free
                } else if !library.directional.isEmpty {
                    assetPool = library.directional
                } else {
                    continue
                }

                guard let asset = assetPool.randomElement(
                    using: &rng
                ) else {
                    continue
                }

                if let placement = tryPlaceWallGlyph(
                    asset: asset,
                    segment: segment,
                    segmentIndexGlyph: index,
                    apertureCenter: center,
                    occupied: &occupied,
                    rng: &rng
                ) {
                    placements.append(placement)
                    occupied.append(placement.obb)
                }
            }
        }

        print(
            """
            [PortalGlyphs] wall placements generated
              segments: \(segments.count)
              placements: \(placements.count)
              occupied: \(occupied.count)
            """
        )

        return placements
    }

    static func generateFloorPlacements(
        seed: UInt64,
        library: PortalGlyphAssetLibrary,
        portalWidth: Float
    ) -> [PortalGlyphPlacement] {
        guard !library.floor.isEmpty else {
            return []
        }

        var rng = SeededRNG(seed: seed ^ 0xF100D)
        var placements: [PortalGlyphPlacement] = []
        var occupied: [PortalGlyphOBB] = []

        let count = Int.random(
            in: PortalGlyphFXSettings.floorGlyphCountRange,
            using: &rng
        )

        for _ in 0..<count {
            guard let asset = library.floor.randomElement(
                using: &rng
            ) else {
                continue
            }

            let size = asset.physicalSize(
                pixelsPerMeter: PortalGlyphFXSettings.pixelsPerMeter
            )

            for _ in 0..<18 {
                let x = Float.random(
                    in: -max(portalWidth, PortalGlyphFXSettings.floorSideSpread)...max(portalWidth, PortalGlyphFXSettings.floorSideSpread),
                    using: &rng
                )

                let z = Float.random(
                    in: PortalGlyphFXSettings.floorForwardMin...PortalGlyphFXSettings.floorForwardMax,
                    using: &rng
                )

                let angle = Float.random(
                    in: -0.45...0.45,
                    using: &rng
                )

                let axisX = SIMD2<Float>(
                    cos(angle),
                    sin(angle)
                )

                let axisY = SIMD2<Float>(
                    -sin(angle),
                    cos(angle)
                )

                let center = SIMD2<Float>(
                    x,
                    z
                )

                let obb = PortalGlyphOBB(
                    center: center,
                    axisX: normalizeSafe2(
                        axisX,
                        fallback: SIMD2<Float>(1, 0)
                    ),
                    axisY: normalizeSafe2(
                        axisY,
                        fallback: SIMD2<Float>(0, 1)
                    ),
                    halfSize: size * 0.5
                )

                let overlaps = occupied.contains {
                    $0.overlaps(
                        obb,
                        padding: PortalGlyphFXSettings.floorGlyphPadding
                    )
                }

                if !overlaps {
                    let placement = PortalGlyphPlacement(
                        asset: asset,
                        surface: .floor,
                        center2D: center,
                        axisX: obb.axisX,
                        axisY: obb.axisY,
                        size: size,
                        rotationRadians: angle,
                        obb: obb
                    )

                    placements.append(placement)
                    occupied.append(obb)
                    break
                }
            }
        }

        print(
            """
            [PortalGlyphs] floor placements generated
              placements: \(placements.count)
              portalWidth: \(portalWidth)
            """
        )

        return placements
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

            out.append(
                GlyphSegment(
                    index: index,
                    a: a,
                    b: b,
                    midpoint: midpoint,
                    direction: direction,
                    outward: normalizeSafe2(
                        perpendicular,
                        fallback: SIMD2<Float>(0, 1)
                    ),
                    length: length
                )
            )
        }

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

    static func tryPlaceWallGlyph(
        asset: PortalGlyphAsset,
        segment: GlyphSegment,
        segmentIndexGlyph: Int,
        apertureCenter: SIMD3<Float>,
        occupied: inout [PortalGlyphOBB],
        rng: inout SeededRNG
    ) -> PortalGlyphPlacement? {
        let size = asset.physicalSize(
            pixelsPerMeter: PortalGlyphFXSettings.pixelsPerMeter
        )

        let isDirectional = asset.kind == .directional

        for attempt in 0..<18 {
            let along = Float.random(
                in: 0.08...0.92,
                using: &rng
            )

            let base = segment.a + (segment.b - segment.a) * along
            let lane = Float(
                (segmentIndexGlyph + attempt) % PortalGlyphFXSettings.directionalMaxLanes
            )

            let laneOffset =
                PortalGlyphFXSettings.directionalLaneSpacing * (lane + 1)

            let randomScatter = isDirectional
                ? SIMD2<Float>.zero
                : SIMD2<Float>(
                    Float.random(
                        in: -PortalGlyphFXSettings.freeGlyphScatterRadius...PortalGlyphFXSettings.freeGlyphScatterRadius,
                        using: &rng
                    ),
                    Float.random(
                        in: -PortalGlyphFXSettings.freeGlyphScatterRadius...PortalGlyphFXSettings.freeGlyphScatterRadius,
                        using: &rng
                    )
                )

            let center =
                base +
                segment.outward * laneOffset +
                randomScatter

            let axisX: SIMD2<Float>
            let axisY: SIMD2<Float>
            let rotation: Float

            if isDirectional {
                axisX = segment.direction
                axisY = SIMD2<Float>(
                    -segment.direction.y,
                    segment.direction.x
                )
                rotation = atan2(
                    segment.direction.y,
                    segment.direction.x
                )
            } else {
                let angle = Float.random(
                    in: 0...(2 * .pi),
                    using: &rng
                )
                axisX = SIMD2<Float>(
                    cos(angle),
                    sin(angle)
                )
                axisY = SIMD2<Float>(
                    -sin(angle),
                    cos(angle)
                )
                rotation = angle
            }

            let obb = PortalGlyphOBB(
                center: center,
                axisX: normalizeSafe2(
                    axisX,
                    fallback: SIMD2<Float>(1, 0)
                ),
                axisY: normalizeSafe2(
                    axisY,
                    fallback: SIMD2<Float>(0, 1)
                ),
                halfSize: size * 0.5
            )

            let overlaps = occupied.contains {
                $0.overlaps(
                    obb,
                    padding: PortalGlyphFXSettings.wallGlyphPadding
                )
            }

            if !overlaps {
                return PortalGlyphPlacement(
                    asset: asset,
                    surface: .wall,
                    center2D: center,
                    axisX: obb.axisX,
                    axisY: obb.axisY,
                    size: size,
                    rotationRadians: rotation,
                    obb: obb
                )
            }
        }

        return nil
    }
}
