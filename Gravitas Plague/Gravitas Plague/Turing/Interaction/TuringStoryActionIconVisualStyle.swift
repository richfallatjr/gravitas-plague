import RealityKit
import UIKit

@MainActor
enum TuringStoryActionIconVisualStyle {
    static let textureSize = CGSize(width: 256, height: 256)

    static func material(symbolName: String) throws -> UnlitMaterial {
        let texture = try TextureResource(
            image: makeImage(symbolName: symbolName),
            withName: "turing_story_hot_action_\(symbolName)",
            options: .init(semantic: .color)
        )
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        material.faceCulling = .none
        return material
    }

    static func material(
        name: String,
        drawGlyph: (CGContext, CGRect) -> Void
    ) throws -> UnlitMaterial {
        let image = makeImage(name: name, drawGlyph: drawGlyph)
        let texture = try TextureResource(
            image: image,
            withName: "turing_story_hot_action_\(name)",
            options: .init(semantic: .color)
        )
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        material.faceCulling = .none
        return material
    }

    private static func makeImage(symbolName: String) throws -> CGImage {
        let glyphName: String
        switch symbolName {
        case "play.circle": glyphName = "play.fill"
        case "mic.circle": glyphName = "mic.fill"
        default: glyphName = symbolName
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: 150, weight: .bold)
        guard let symbol = UIImage(
            systemName: glyphName,
            withConfiguration: configuration
        )?.withTintColor(
            UIColor(
                red: 0.992,
                green: 0.914,
                blue: 0.643,
                alpha: 1
            ),
            renderingMode: .alwaysOriginal
        ) else {
            throw TuringRuntimeError.invalidConfig("Unable to render Story action icon \(symbolName).")
        }
        return makeImage(name: symbolName) { _, rect in
            let maximumGlyphSize = CGSize(width: 112, height: 112)
            let sourceSize = symbol.size
            let scale = min(
                maximumGlyphSize.width / sourceSize.width,
                maximumGlyphSize.height / sourceSize.height
            )
            let drawSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            symbol.draw(
                in: CGRect(
                    x: rect.midX - drawSize.width * 0.5,
                    y: rect.midY - drawSize.height * 0.5,
                    width: drawSize.width,
                    height: drawSize.height
                )
            )
        }
    }

    private static func makeImage(
        name _: String,
        drawGlyph: (CGContext, CGRect) -> Void
    ) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: textureSize)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let rect = CGRect(origin: .zero, size: textureSize)
            context.clear(rect)
            drawGradient(in: context, center: CGPoint(x: rect.midX, y: rect.midY), radius: 126)

            context.setFillColor(UIColor(red: 0.208, green: 0.063, blue: 0.047, alpha: 0.93).cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 42, dy: 42))

            context.setStrokeColor(UIColor(red: 1.0, green: 0.478, blue: 0.141, alpha: 1).cgColor)
            context.setLineWidth(11)
            context.strokeEllipse(in: rect.insetBy(dx: 34, dy: 34))
            context.setStrokeColor(UIColor(red: 0.863, green: 0.251, blue: 0.122, alpha: 0.9).cgColor)
            context.setLineWidth(5)
            context.strokeEllipse(in: rect.insetBy(dx: 25, dy: 25))
            drawGlyph(context, rect)
        }
        return image.cgImage!
    }

    private static func drawGradient(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        let colors = [
            UIColor(red: 0.992, green: 0.914, blue: 0.643, alpha: 0.98).cgColor,
            UIColor(red: 0.973, green: 0.765, blue: 0.463, alpha: 0.94).cgColor,
            UIColor(red: 1.0, green: 0.478, blue: 0.141, alpha: 0.82).cgColor,
            UIColor(red: 0.863, green: 0.251, blue: 0.122, alpha: 0.56).cgColor,
            UIColor(red: 0.631, green: 0.157, blue: 0.027, alpha: 0.88).cgColor,
            UIColor(red: 0.631, green: 0.157, blue: 0.027, alpha: 0.0).cgColor
        ] as CFArray
        let locations: [CGFloat] = [0, 0.32, 0.58, 0.78, 0.92, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
    }
}
