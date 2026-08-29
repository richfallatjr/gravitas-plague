import Foundation
import Metal
import simd

nonisolated enum MindEyePackedLayerBuilderError: Error, Sendable, Equatable {
    case invalidDimensions
    case invalidRowBytes
    case invalidBufferLength
    case emptyChangingLayer
    case textureCreationFailed
}

nonisolated enum MindEyePackedLayerBuilder {
    static let alphaThreshold: UInt8 = 0
    static let paddingPixels = 4
    static let alignmentPixels = 4
    static let fullCanvasFallbackOccupancy = 0.85

    static func alphaBounds(
        rgba8: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil
    ) throws -> MindEyeAlphaBounds {
        guard width > 0, height > 0 else {
            throw MindEyePackedLayerBuilderError.invalidDimensions
        }
        let rowBytes = bytesPerRow ?? width * 4
        guard rowBytes >= width * 4 else {
            throw MindEyePackedLayerBuilderError.invalidRowBytes
        }
        let required = rowBytes.multipliedReportingOverflow(by: height)
        guard !required.overflow, rgba8.count >= required.partialValue else {
            throw MindEyePackedLayerBuilderError.invalidBufferLength
        }
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            let rowStart = y * rowBytes
            for x in 0..<width where rgba8[rowStart + x * 4 + 3] > alphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + 1)
                maxY = max(maxY, y + 1)
            }
        }
        guard minX < maxX, minY < maxY else {
            throw MindEyePackedLayerBuilderError.emptyChangingLayer
        }
        return MindEyeAlphaBounds(
            minX: minX,
            minY: minY,
            maxXExclusive: maxX,
            maxYExclusive: maxY
        )
    }

    static func retainedBounds(
        rgba8: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil
    ) throws -> MindEyeAlphaBounds {
        try alphaBounds(
            rgba8: rgba8,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
        .padded(pixels: paddingPixels, canvasWidth: width, canvasHeight: height)
        .alignedOutward(
            multiple: alignmentPixels,
            canvasWidth: width,
            canvasHeight: height
        )
    }

    static func shouldPack(
        bounds: MindEyeAlphaBounds,
        canvasWidth: Int,
        canvasHeight: Int,
        policy: MindEyePackedLayerPolicy
    ) -> Bool {
        guard policy == .transparentOverlaysOnly,
              canvasWidth > 0,
              canvasHeight > 0 else { return false }
        let canvasArea = Double(canvasWidth) * Double(canvasHeight)
        return Double(bounds.area) / canvasArea < fullCanvasFallbackOccupancy
    }

    static func build(
        device: any MTLDevice,
        sourceTexture: any MTLTexture,
        rgba8: [UInt8],
        bytesPerRow: Int,
        policy: MindEyePackedLayerPolicy
    ) throws -> MindEyePackedLayerTexture {
        let width = sourceTexture.width
        let height = sourceTexture.height
        let bounds = try retainedBounds(
            rgba8: rgba8,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
        let sourceBytes = UInt64(sourceTexture.allocatedSize)
        guard shouldPack(
            bounds: bounds,
            canvasWidth: width,
            canvasHeight: height,
            policy: policy
        ) else {
            return MindEyePackedLayerTexture(
                layer: MindEyeLayerTexture(
                    texture: sourceTexture,
                    sourceRect: .fullCanvas(
                        width: UInt32(width),
                        height: UInt32(height)
                    ),
                    isPacked: false
                ),
                alphaBounds: bounds,
                sourceAllocatedBytes: sourceBytes,
                retainedAllocatedBytes: sourceBytes
            )
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sourceTexture.pixelFormat,
            width: bounds.width,
            height: bounds.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MindEyePackedLayerBuilderError.textureCreationFailed
        }
        var cropped = [UInt8](repeating: 0, count: bounds.width * bounds.height * 4)
        for row in 0..<bounds.height {
            let sourceStart = (bounds.minY + row) * bytesPerRow + bounds.minX * 4
            let targetStart = row * bounds.width * 4
            cropped.replaceSubrange(
                targetStart..<(targetStart + bounds.width * 4),
                with: rgba8[sourceStart..<(sourceStart + bounds.width * 4)]
            )
        }
        cropped.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, bounds.width, bounds.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: bounds.width * 4
            )
        }
        return MindEyePackedLayerTexture(
            layer: MindEyeLayerTexture(
                texture: texture,
                sourceRect: MindEyeLayerSourceRect(
                    originPixels: SIMD2(UInt32(bounds.minX), UInt32(bounds.minY)),
                    sizePixels: SIMD2(UInt32(bounds.width), UInt32(bounds.height)),
                    canvasSizePixels: SIMD2(UInt32(width), UInt32(height))
                ),
                isPacked: true
            ),
            alphaBounds: bounds,
            sourceAllocatedBytes: sourceBytes,
            retainedAllocatedBytes: UInt64(texture.allocatedSize)
        )
    }
}
