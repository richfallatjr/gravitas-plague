import simd

struct PortalGlyphOBB {
    var center: SIMD2<Float>
    var axisX: SIMD2<Float>
    var axisY: SIMD2<Float>
    var halfSize: SIMD2<Float>

    func overlaps(
        _ other: PortalGlyphOBB,
        padding: Float
    ) -> Bool {
        let clampedPadding = max(
            0,
            padding
        )

        let axes = [
            axisX,
            axisY,
            other.axisX,
            other.axisY
        ]

        for axis in axes {
            let normalized = normalizeSafe2(
                axis,
                fallback: SIMD2<Float>(1, 0)
            )

            let a = projectedRadius(
                on: normalized,
                padding: clampedPadding
            )

            let b = other.projectedRadius(
                on: normalized,
                padding: clampedPadding
            )

            let distance = abs(
                simd_dot(
                    other.center - center,
                    normalized
                )
            )

            if distance >= a + b {
                return false
            }
        }

        return true
    }

    private func projectedRadius(
        on axis: SIMD2<Float>,
        padding: Float
    ) -> Float {
        abs(simd_dot(axisX, axis)) * (halfSize.x + padding) +
            abs(simd_dot(axisY, axis)) * (halfSize.y + padding)
    }
}

func normalizeSafe2(
    _ vector: SIMD2<Float>,
    fallback: SIMD2<Float>
) -> SIMD2<Float> {
    let length = simd_length(vector)

    guard length > 0.00001 else {
        return fallback
    }

    return vector / length
}

enum PortalGlyphPlacementSurface {
    case wall
    case floor
}

extension PortalGlyphAsset {
    var allowedSurface: PortalGlyphPlacementSurface {
        switch kind {
        case .floor:
            return .floor

        case .directional, .free:
            return .wall
        }
    }
}

struct PortalGlyphPlacement {
    let asset: PortalGlyphAsset
    let surface: PortalGlyphPlacementSurface
    let center2D: SIMD2<Float>
    let axisX: SIMD2<Float>
    let axisY: SIMD2<Float>
    let size: SIMD2<Float>
    let rotationRadians: Float
    let obb: PortalGlyphOBB
}
