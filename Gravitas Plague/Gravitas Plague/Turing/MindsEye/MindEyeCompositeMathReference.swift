import Foundation
import simd

nonisolated enum MindEyeCompositeMathReference {
    static func sourceOverPremultiplied(
        under: SIMD4<Float>,
        over: SIMD4<Float>
    ) -> SIMD4<Float> {
        let remaining = 1 - over.w
        return SIMD4<Float>(
            over.x + under.x * remaining,
            over.y + under.y * remaining,
            over.z + under.z * remaining,
            over.w + under.w * remaining
        )
    }

    static func maskLuminance(_ rgb: SIMD3<Float>) -> Float {
        let luminance = max(
            0,
            min(1, simd_dot(rgb, SIMD3<Float>(0.2126, 0.7152, 0.0722)))
        )
        let blackPoint: Float = 22.0 / 255.0
        return max(0, min(1, (luminance - blackPoint) / (1 - blackPoint)))
    }

    static func applyMask(
        premultiplied: SIMD4<Float>,
        maskRGB: SIMD3<Float>
    ) -> SIMD4<Float> {
        let sourceAlpha = premultiplied.w
        let straightRGB = sourceAlpha > 0.0000152588
            ? SIMD3<Float>(premultiplied.x, premultiplied.y, premultiplied.z) / sourceAlpha
            : .zero
        return SIMD4<Float>(
            straightRGB.x,
            straightRGB.y,
            straightRGB.z,
            sourceAlpha * maskLuminance(maskRGB)
        )
    }
}
