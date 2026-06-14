import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd
import UIKit

enum PortalGlyphKind: String {
    case directional
    case floor
    case free
}

struct PortalGlyphAsset: Identifiable {
    let id: String
    let url: URL
    let fileName: String
    let kind: PortalGlyphKind
    let pixelWidth: Int
    let pixelHeight: Int
    let texture: TextureResource

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
}

enum PortalGlyphAssetClassifier {
    static func classify(
        fileName: String
    ) -> PortalGlyphKind {
        let lower = fileName.lowercased()

        if lower.hasSuffix("floor.png") {
            return .floor
        }

        if lower.hasSuffix("dir.png") {
            return .directional
        }

        return .free
    }
}

@MainActor
final class PortalGlyphAssetLibrary {
    static let shared = PortalGlyphAssetLibrary()

    private(set) var all: [PortalGlyphAsset] = []
    private(set) var directional: [PortalGlyphAsset] = []
    private(set) var floor: [PortalGlyphAsset] = []
    private(set) var free: [PortalGlyphAsset] = []

    private var didLoad = false

    private init() {}

    func loadIfNeeded() {
        guard !didLoad else {
            return
        }

        didLoad = true

        guard let folderURL = Bundle.main.url(
            forResource: "PortalGlyphs",
            withExtension: nil
        ) else {
            print(
                """
                [PortalGlyphs] WARNING PortalGlyphs folder not found
                  expected: Bundle/PortalGlyphs
                  action: glyph_layer_disabled
                """
            )
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.pathExtension.lowercased() == "png"
            }
            .sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }

            var loaded: [PortalGlyphAsset] = []

            for url in urls {
                do {
                    loaded.append(
                        try loadAsset(
                            url: url
                        )
                    )
                } catch {
                    print(
                        """
                        [PortalGlyphs] ERROR failed loading glyph
                          file: \(url.lastPathComponent)
                          error: \(error.localizedDescription)
                        """
                    )
                }
            }

            all = loaded
            directional = loaded.filter { $0.kind == .directional }
            floor = loaded.filter { $0.kind == .floor }
            free = loaded.filter { $0.kind == .free }

            print(
                """
                [PortalGlyphs] library loaded
                  folder: \(folderURL.path)
                  total: \(all.count)
                  directional: \(directional.count)
                  floor: \(floor.count)
                  free: \(free.count)
                  naming: *dir.png, *floor.png, *.png
                """
            )

            print(
                """
                [PortalGlyphs] size mapping active
                  pixelsPerFoot: \(PortalGlyphFXSettings.pixelsPerFoot)
                  noRuntimeScale: true
                """
            )
        } catch {
            print(
                """
                [PortalGlyphs] ERROR failed enumerating folder
                  folder: \(folderURL.path)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    private func loadAsset(
        url: URL
    ) throws -> PortalGlyphAsset {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not create CGImageSource"
                ]
            )
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any] else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not read image properties"
                ]
            )
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        guard width > 0, height > 0 else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Bad pixel dimensions"
                ]
            )
        }

        let texture = try makeLuminanceMaskTexture(
            source: source,
            fileName: url.lastPathComponent
        )

        let fileName = url.lastPathComponent
        let kind = PortalGlyphAssetClassifier.classify(
            fileName: fileName
        )

        let asset = PortalGlyphAsset(
            id: fileName,
            url: url,
            fileName: fileName,
            kind: kind,
            pixelWidth: width,
            pixelHeight: height,
            texture: texture
        )

        print(
            """
            [PortalGlyphs] loaded glyph
              file: \(fileName)
              kind: \(kind.rawValue)
              pixels: \(width)x\(height)
              maskRule: white_opaque_black_transparent
              colorSource: material_constant
            """
        )

        return asset
    }

    private func makeLuminanceMaskTexture(
        source: CGImageSource,
        fileName: String
    ) throws -> TextureResource {
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not decode image"
                ]
            )
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var input = [UInt8](
            repeating: 0,
            count: byteCount
        )

        let inputInfo =
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue

        guard let inputContext = CGContext(
            data: &input,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: inputInfo
        ) else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not create input bitmap context"
                ]
            )
        }

        inputContext.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        )

        var output = [UInt8](
            repeating: 0,
            count: byteCount
        )

        for offset in stride(
            from: 0,
            to: byteCount,
            by: bytesPerPixel
        ) {
            let red = UInt32(input[offset])
            let green = UInt32(input[offset + 1])
            let blue = UInt32(input[offset + 2])
            let sourceAlpha = UInt32(input[offset + 3])

            let luminance =
                (red * 299 + green * 587 + blue * 114) / 1000
            let maskAlpha = UInt8(
                min(
                    UInt32(255),
                    luminance * sourceAlpha / 255
                )
            )

            output[offset] = 255
            output[offset + 1] = 255
            output[offset + 2] = 255
            output[offset + 3] = maskAlpha
        }

        let data = Data(output)

        guard let provider = CGDataProvider(
            data: data as CFData
        ) else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not create mask data provider"
                ]
            )
        }

        let outputInfo =
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.last.rawValue

        guard let maskImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: outputInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw NSError(
                domain: "PortalGlyphs",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not create mask image"
                ]
            )
        }

        return try TextureResource(
            image: maskImage,
            withName: "\(fileName)_luminance_mask",
            options: .init(semantic: .color)
        )
    }
}
