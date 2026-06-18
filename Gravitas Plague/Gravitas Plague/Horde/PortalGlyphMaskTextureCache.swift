import CoreGraphics
import Foundation
import ImageIO
import RealityKit

@MainActor
final class PortalGlyphMaskTextureCache {
    static let shared = PortalGlyphMaskTextureCache()

    private var textureBySourcePath: [String: TextureResource] = [:]

    private init() {}

    func textureForMaskPNG(
        url: URL
    ) throws -> TextureResource {
        let key = url.path

        if let cached = textureBySourcePath[key] {
            return cached
        }

        let image = try makeAlphaMaskImage(
            sourceURL: url
        )

        let texture = try TextureResource(
            image: image,
            withName: "\(url.deletingPathExtension().lastPathComponent)_alphaMask",
            options: .init(semantic: .color)
        )

        textureBySourcePath[key] = texture

        print(
            """
            [PortalGlyphs] mask texture generated
              source: \(url.lastPathComponent)
              rule: white_opaque_black_transparent
              greyPartialAlpha: true
              directTextureDisplay: false
            """
        )

        return texture
    }

    private func makeAlphaMaskImage(
        sourceURL: URL
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            nil
        ) else {
            throw maskError(
                code: 1,
                message: "Could not create image source"
            )
        }

        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else {
            throw maskError(
                code: 2,
                message: "Could not decode source image"
            )
        }

        let width = image.width
        let height = image.height

        guard width > 0,
              height > 0 else {
            throw maskError(
                code: 3,
                message: "Invalid source image size"
            )
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var sourcePixels = [UInt8](
            repeating: 0,
            count: byteCount
        )

        let bitmapInfo =
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue

        guard let sourceContext = CGContext(
            data: &sourcePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw maskError(
                code: 4,
                message: "Could not create source context"
            )
        }

        sourceContext.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        )

        var outputPixels = [UInt8](
            repeating: 0,
            count: byteCount
        )

        for offset in stride(
            from: 0,
            to: byteCount,
            by: bytesPerPixel
        ) {
            let r = Float(sourcePixels[offset])
            let g = Float(sourcePixels[offset + 1])
            let b = Float(sourcePixels[offset + 2])
            let sourceAlpha = Float(sourcePixels[offset + 3]) / 255.0

            let luminance =
                0.2126 * r +
                0.7152 * g +
                0.0722 * b

            let alpha = UInt8(
                max(
                    0,
                    min(
                        255,
                        Int((luminance * sourceAlpha).rounded())
                    )
                )
            )

            // Premultiplied white by alpha. This prevents black square/halo leaks.
            outputPixels[offset] = alpha
            outputPixels[offset + 1] = alpha
            outputPixels[offset + 2] = alpha
            outputPixels[offset + 3] = alpha
        }

        guard let outputContext = CGContext(
            data: &outputPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw maskError(
                code: 5,
                message: "Could not create output context"
            )
        }

        guard let output = outputContext.makeImage() else {
            throw maskError(
                code: 6,
                message: "Could not create output image"
            )
        }

        return output
    }

    private func maskError(
        code: Int,
        message: String
    ) -> NSError {
        NSError(
            domain: "PortalGlyphMask",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }
}

