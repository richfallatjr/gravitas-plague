import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd
import UIKit

enum PortalGlyphKind: String, Sendable {
    case directional
    case floor
    case circle
    case free
}

struct PortalGlyphAsset: Identifiable {
    let id: String
    let url: URL
    let fileName: String
    let kind: PortalGlyphKind
    let pixelWidth: Int
    let pixelHeight: Int

    /// RGB is premultiplied white by alpha. Alpha comes from source PNG luminance.
    let alphaMaskTexture: TextureResource

    var aspect: Float {
        Float(pixelWidth) / Float(max(pixelHeight, 1))
    }
}

struct PortalGlyphAssetLibrarySnapshot: Sendable {
    let all: [PortalGlyphAssetDescriptor]
    let directional: [PortalGlyphAssetDescriptor]
    let floor: [PortalGlyphAssetDescriptor]
    let circle: [PortalGlyphAssetDescriptor]
    let free: [PortalGlyphAssetDescriptor]
}

extension PortalGlyphAsset {
    var layoutDescriptor: PortalGlyphAssetDescriptor {
        PortalGlyphAssetDescriptor(
            id: id,
            fileName: fileName,
            kind: kind,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
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

        if lower.hasSuffix("circle.png") {
            return .circle
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
    private(set) var circle: [PortalGlyphAsset] = []
    private(set) var free: [PortalGlyphAsset] = []

    private var didLoad = false
    private var assetByID: [String: PortalGlyphAsset] = [:]

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
            circle = loaded.filter { $0.kind == .circle }
            free = loaded.filter { $0.kind == .free }
            assetByID = Dictionary(
                uniqueKeysWithValues: loaded.map {
                    ($0.id, $0)
                }
            )

            print(
                """
                [PortalGlyphs] library loaded
                  folder: \(folderURL.path)
                  total: \(all.count)
                  directional: \(directional.count)
                  circle: \(circle.count)
                  floor: \(floor.count)
                  free: \(free.count)
                  naming: *dir.png, *circle.png, *floor.png, *.png
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

    var layoutSnapshot: PortalGlyphAssetLibrarySnapshot {
        PortalGlyphAssetLibrarySnapshot(
            all: all.map(\.layoutDescriptor),
            directional: directional.map(\.layoutDescriptor),
            floor: floor.map(\.layoutDescriptor),
            circle: circle.map(\.layoutDescriptor),
            free: free.map(\.layoutDescriptor)
        )
    }

    func asset(
        id: String
    ) -> PortalGlyphAsset? {
        assetByID[id]
    }

    func placement(
        from descriptor: PortalGlyphPlacementDescriptor
    ) -> PortalGlyphPlacement? {
        guard let asset = asset(
            id: descriptor.asset.id
        ) else {
            return nil
        }

        return PortalGlyphPlacement(
            descriptor: descriptor,
            asset: asset
        )
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

        let alphaMaskTexture: TextureResource

        do {
            alphaMaskTexture = try PortalGlyphMaskTextureCache.shared.textureForMaskPNG(
                url: url
            )
        } catch {
            print(
                """
                [PortalGlyphs] ERROR failed to create alpha mask glyph
                  file: \(url.lastPathComponent)
                  action: skip_glyph
                  fallbackSquare: false
                  error: \(error.localizedDescription)
                """
            )

            throw error
        }

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
            alphaMaskTexture: alphaMaskTexture
        )

        let aspect =
            Float(width) / Float(max(height, 1))

        print(
            """
            [PortalGlyphs] loaded mask glyph
              file: \(fileName)
              kind: \(kind.rawValue)
              pixels: \(width)x\(height)
              aspect: \(aspect)
              physicalSizeMeters: \(asset.physicalSizeMeters())
              aspectPreserved: true
              alphaSource: luminance
              whiteOpaque: true
              blackTransparent: true
              directTextureDisplay: false
            """
        )

        return asset
    }
}
