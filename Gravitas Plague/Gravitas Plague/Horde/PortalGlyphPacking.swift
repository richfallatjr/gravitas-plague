import simd

struct PortalGlyphOBB: Sendable {
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

enum PortalGlyphPlacementSurface: Sendable {
    case wall
    case floor
}

enum PortalGlyphOrientationPolicy: String, Sendable {
    case followSegment
    case wallYUp
    case floor
}

enum PortalGlyphWallAxes {
    static let xRight = SIMD2<Float>(1, 0)
    static let yUp = SIMD2<Float>(0, 1)
    static let yUpRotationRadians: Float = 0
}

extension PortalGlyphAsset {
    var allowedSurface: PortalGlyphPlacementSurface {
        switch kind {
        case .floor:
            return .floor

        case .directional, .circle, .free:
            return .wall
        }
    }

    var orientationPolicy: PortalGlyphOrientationPolicy {
        switch kind {
        case .directional:
            return .followSegment

        case .free, .circle:
            return .wallYUp

        case .floor:
            return .floor
        }
    }
}

struct PortalGlyphAssetDescriptor: Identifiable, Sendable {
    let id: String
    let fileName: String
    let kind: PortalGlyphKind
    let pixelWidth: Int
    let pixelHeight: Int

    var aspect: Float {
        Float(pixelWidth) / Float(max(pixelHeight, 1))
    }

    func physicalSizeMeters() -> SIMD2<Float> {
        let widthFeet =
            Float(pixelWidth) / PortalGlyphFXSettings.pixelsPerFoot

        let heightFeet =
            Float(pixelHeight) / PortalGlyphFXSettings.pixelsPerFoot

        return SIMD2<Float>(
            widthFeet * PortalGlyphFXSettings.feetToMeters,
            heightFeet * PortalGlyphFXSettings.feetToMeters
        )
    }

    var allowedSurface: PortalGlyphPlacementSurface {
        switch kind {
        case .floor:
            return .floor

        case .directional, .circle, .free:
            return .wall
        }
    }

    var orientationPolicy: PortalGlyphOrientationPolicy {
        switch kind {
        case .directional:
            return .followSegment

        case .free, .circle:
            return .wallYUp

        case .floor:
            return .floor
        }
    }
}

struct PortalGlyphPlacementDescriptor: Sendable {
    let asset: PortalGlyphAssetDescriptor
    let surface: PortalGlyphPlacementSurface
    let center2D: SIMD2<Float>
    let axisX: SIMD2<Float>
    let axisY: SIMD2<Float>
    let size: SIMD2<Float>
    let rotationRadians: Float
    let obb: PortalGlyphOBB
    let sourceSegmentIndex: Int?
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
    let sourceSegmentIndex: Int?
}

extension PortalGlyphPlacement {
    init(
        descriptor: PortalGlyphPlacementDescriptor,
        asset: PortalGlyphAsset
    ) {
        self.asset = asset
        self.surface = descriptor.surface
        self.center2D = descriptor.center2D
        self.axisX = descriptor.axisX
        self.axisY = descriptor.axisY
        self.size = descriptor.size
        self.rotationRadians = descriptor.rotationRadians
        self.obb = descriptor.obb
        self.sourceSegmentIndex = descriptor.sourceSegmentIndex
    }
}
