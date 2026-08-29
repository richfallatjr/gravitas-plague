import Foundation
import simd

nonisolated enum MindEyeCompositeGeometry {
    static let sourceSize = SIMD2<Float>(2_304, 1_296)
    static let outputSize = SIMD2<Float>(1_920, 1_080)
    static let cropOrigin = SIMD2<Float>(192, 108)
    static var sourceViewportCenter: SIMD2<Float> {
        cropOrigin + outputSize * 0.5
    }

    static func sourcePixelCenter(
        outputPixelCenter: SIMD2<Float>,
        transform: MindEyeLayerTransform
    ) -> SIMD2<Float> {
        let outputCenter = outputSize * 0.5
        let logicalYUp = SIMD2<Float>(
            outputPixelCenter.x - outputCenter.x,
            outputCenter.y - outputPixelCenter.y
        )
        var local = logicalYUp - transform.translationPixels
        let inverseRoll = -transform.rollRadians
        let cosine = cos(inverseRoll)
        let sine = sin(inverseRoll)
        local = SIMD2<Float>(
            cosine * local.x - sine * local.y,
            sine * local.x + cosine * local.y
        )
        local /= transform.scale
        return SIMD2<Float>(
            sourceViewportCenter.x + local.x,
            sourceViewportCenter.y - local.y
        )
    }
}

nonisolated struct MindEyeSamplingFootprint: Sendable, Equatable {
    let corners: [SIMD2<Float>]
    let min: SIMD2<Float>
    let max: SIMD2<Float>
}

nonisolated enum MindEyeSamplingFootprintResolver {
    static func resolve(
        transform: MindEyeLayerTransform
    ) -> MindEyeSamplingFootprint {
        let output = MindEyeCompositeGeometry.outputSize
        let outputCorners = [
            SIMD2<Float>(0.5, 0.5),
            SIMD2<Float>(output.x - 0.5, 0.5),
            SIMD2<Float>(0.5, output.y - 0.5),
            SIMD2<Float>(output.x - 0.5, output.y - 0.5)
        ]
        let corners = outputCorners.map {
            MindEyeCompositeGeometry.sourcePixelCenter(
                outputPixelCenter: $0,
                transform: transform
            )
        }
        let minimum = corners.reduce(
            SIMD2<Float>(repeating: .greatestFiniteMagnitude),
            simd_min
        )
        let maximum = corners.reduce(
            SIMD2<Float>(repeating: -.greatestFiniteMagnitude),
            simd_max
        )
        return MindEyeSamplingFootprint(corners: corners, min: minimum, max: maximum)
    }

    static func isSafe(
        _ footprint: MindEyeSamplingFootprint,
        sourceSize: SIMD2<Float> = MindEyeCompositeGeometry.sourceSize,
        bilinearGuardPixels: Float = 1
    ) -> Bool {
        footprint.min.x >= bilinearGuardPixels &&
            footprint.min.y >= bilinearGuardPixels &&
            footprint.max.x <= sourceSize.x - bilinearGuardPixels &&
            footprint.max.y <= sourceSize.y - bilinearGuardPixels
    }
}

nonisolated struct MindEyeSanitizedLayerTransform: Sendable, Equatable {
    let value: MindEyeLayerTransform
    let wasClamped: Bool
}

nonisolated enum MindEyeLayerTransformSanitizer {
    static func sanitize(
        _ requested: MindEyeLayerTransform,
        maximumIterations: Int = 16
    ) -> Result<MindEyeSanitizedLayerTransform, MindEyeFailure> {
        guard requested.isFiniteAndPositive, maximumIterations > 0 else {
            return .failure(failure("Composite transform is invalid."))
        }
        if isSafe(requested) {
            return .success(.init(value: requested, wasClamped: false))
        }
        guard isSafe(.identity) else {
            return .failure(failure("Identity crop is not safe for the configured dimensions."))
        }

        var lower: Float = 0
        var upper: Float = 1
        var best = MindEyeLayerTransform.identity
        for _ in 0..<maximumIterations {
            let amount = (lower + upper) * 0.5
            let candidate = interpolate(from: .identity, to: requested, amount: amount)
            if isSafe(candidate) {
                lower = amount
                best = candidate
            } else {
                upper = amount
            }
        }
        return .success(.init(value: best, wasClamped: true))
    }

    private static func isSafe(_ transform: MindEyeLayerTransform) -> Bool {
        MindEyeSamplingFootprintResolver.isSafe(
            MindEyeSamplingFootprintResolver.resolve(transform: transform)
        )
    }

    private static func interpolate(
        from: MindEyeLayerTransform,
        to: MindEyeLayerTransform,
        amount: Float
    ) -> MindEyeLayerTransform {
        MindEyeLayerTransform(
            translationPixels: simd_mix(
                from.translationPixels,
                to.translationPixels,
                SIMD2<Float>(repeating: amount)
            ),
            rollRadians: from.rollRadians + (to.rollRadians - from.rollRadians) * amount,
            scale: from.scale + (to.scale - from.scale) * amount
        )
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .unsafeCompositeCrop,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
