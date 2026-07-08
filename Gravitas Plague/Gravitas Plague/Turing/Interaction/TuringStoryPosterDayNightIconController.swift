import Foundation
import RealityKit
import UIKit

struct TuringStoryDayNightPosterButtonComponent: Component {
}

@MainActor
final class TuringStoryPosterDayNightIconController {
    private var iconEntity: ModelEntity?

    func install(
        posterContentRoot: Entity,
        posterWidth: Float,
        posterHeight: Float,
        atmosphere: PortalHDRIAtmosphere
    ) {
        remove()

        let size = min(
            WallStickerStyle.stickerSizeMeters,
            posterHeight * 0.105
        )
        let y = -posterHeight * 0.5 - size * 0.90
        let x = -posterWidth * 0.5 + size * 0.65
        let material = makeIconMaterial(
            atmosphere: atmosphere
        )
        let entity = ModelEntity(
            mesh: .generatePlane(
                width: size,
                height: size
            ),
            materials: [material]
        )

        entity.name = "WallPosterDayNight_TuringWindow"
        entity.position = SIMD3<Float>(
            x,
            y,
            0.018
        )
        entity.components.set(TuringStoryDayNightPosterButtonComponent())
        entity.components.set(InputTargetComponent())
        entity.generateCollisionShapes(recursive: true)

        posterContentRoot.addChild(entity)
        iconEntity = entity

        print(
            """
            [TuringWindowPortal] poster day/night icon installed
              name: \(entity.name)
              atmosphere: \(atmosphere.rawValue)
              icon: \(iconName(for: atmosphere))
              style: wall_sticker_two_stops_down
              size: \(size)
            """
        )
    }

    func update(
        atmosphere: PortalHDRIAtmosphere
    ) {
        guard let iconEntity else {
            return
        }

        if var model = iconEntity.components[ModelComponent.self] {
            model.materials = [
                makeIconMaterial(
                    atmosphere: atmosphere
                )
            ]
            iconEntity.components.set(model)
        }

        print(
            """
            [TuringWindowPortal] poster day/night icon updated
              atmosphere: \(atmosphere.rawValue)
              icon: \(iconName(for: atmosphere))
              style: wall_sticker_two_stops_down
            """
        )
    }

    func remove() {
        iconEntity?.removeFromParent()
        iconEntity = nil
    }

    private func makeIconMaterial(
        atmosphere: PortalHDRIAtmosphere
    ) -> UnlitMaterial {
        var material = UnlitMaterial()
        if let texture = try? makeIconTexture(
            atmosphere: atmosphere
        ) {
            material.color = .init(
                tint: WallStickerStyle.twoStopsDownTint,
                texture: .init(texture)
            )
        } else {
            material.color = .init(
                tint: WallStickerStyle.twoStopsDownTint
            )
        }
        material.blending = .transparent(
            opacity: .init(floatLiteral: 0.92)
        )

        return material
    }

    private func makeIconTexture(
        atmosphere: PortalHDRIAtmosphere
    ) throws -> TextureResource {
        let iconName = iconName(
            for: atmosphere
        )
        let image = makeIconImage(
            iconName: iconName
        )

        return try TextureResource(
            image: image,
            withName: "turing_story_window_\(iconName)_sticker",
            options: .init(
                semantic: .color
            )
        )
    }

    private func iconName(
        for atmosphere: PortalHDRIAtmosphere
    ) -> String {
        switch atmosphere {
        case .night:
            return "sun"

        case .overcast:
            return "moon"
        }
    }

    private func makeIconImage(
        iconName: String
    ) -> CGImage {
        let size = CGSize(
            width: 128,
            height: 128
        )
        let renderer = UIGraphicsImageRenderer(
            size: size
        )
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(
                CGRect(
                    origin: .zero,
                    size: size
                )
            )

            switch iconName {
            case "sun":
                drawSunIcon()

            default:
                drawMoonIcon()
            }
        }

        return image.cgImage!
    }

    private func drawSunIcon() {
        UIColor.white.setFill()

        let center = CGPoint(
            x: 64,
            y: 64
        )
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4.0
            let rayCenter = CGPoint(
                x: center.x + cos(angle) * 37,
                y: center.y + sin(angle) * 37
            )
            let path = UIBezierPath(
                roundedRect: CGRect(
                    x: rayCenter.x - 4,
                    y: rayCenter.y - 13,
                    width: 8,
                    height: 26
                ),
                cornerRadius: 4
            )
            path.apply(
                CGAffineTransform(
                    translationX: -rayCenter.x,
                    y: -rayCenter.y
                )
            )
            path.apply(
                CGAffineTransform(
                    rotationAngle: angle
                )
            )
            path.apply(
                CGAffineTransform(
                    translationX: rayCenter.x,
                    y: rayCenter.y
                )
            )
            path.fill()
        }

        UIBezierPath(
            ovalIn: CGRect(
                x: 39,
                y: 39,
                width: 50,
                height: 50
            )
        ).fill()
    }

    private func drawMoonIcon() {
        UIColor.white.setFill()

        UIBezierPath(
            ovalIn: CGRect(
                x: 29,
                y: 20,
                width: 74,
                height: 88
            )
        ).fill()

        UIBezierPath(
            ovalIn: CGRect(
                x: 49,
                y: 18,
                width: 74,
                height: 92
            )
        ).fill(
            with: .clear,
            alpha: 1.0
        )
    }
}
