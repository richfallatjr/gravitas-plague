import Metal
import simd

nonisolated struct MindEyeLayerSourceRect: Sendable, Equatable {
    let originPixels: SIMD2<UInt32>
    let sizePixels: SIMD2<UInt32>
    let canvasSizePixels: SIMD2<UInt32>

    static func fullCanvas(width: UInt32, height: UInt32) -> Self {
        Self(
            originPixels: .zero,
            sizePixels: SIMD2(width, height),
            canvasSizePixels: SIMD2(width, height)
        )
    }

    func canvasPixel(forLocalPixel local: SIMD2<UInt32>) -> SIMD2<UInt32>? {
        guard local.x < sizePixels.x, local.y < sizePixels.y else { return nil }
        let (x, overflowX) = originPixels.x.addingReportingOverflow(local.x)
        let (y, overflowY) = originPixels.y.addingReportingOverflow(local.y)
        guard !overflowX, !overflowY,
              x < canvasSizePixels.x, y < canvasSizePixels.y else { return nil }
        return SIMD2(x, y)
    }
}

nonisolated struct MindEyeLayerTexture: @unchecked Sendable {
    let texture: any MTLTexture
    let sourceRect: MindEyeLayerSourceRect
    let isPacked: Bool
}
