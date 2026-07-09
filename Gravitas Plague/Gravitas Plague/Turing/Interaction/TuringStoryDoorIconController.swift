import Foundation
import RealityKit
import UIKit

@MainActor
final class TuringStoryDoorIconController {
    private var iconEntity: Entity?

    func install(
        anchor: Entity,
        doorID: String = "storyDoor.primary"
    ) {
        remove()
        TuringStoryDoorTriggerComponent.registerComponent()

        let size = WallStickerStyle.stickerSizeMeters
        let material = makeIconMaterial()
        let entity = ModelEntity(
            mesh: .generatePlane(
                width: size,
                height: size
            ),
            materials: [material]
        )

        entity.name = "TuringStoryDoorIcon"
        entity.position = SIMD3<Float>(0, 0, 0)
        entity.components.set(
            TuringStoryDoorTriggerComponent(
                doorID: doorID
            )
        )
        entity.components.set(InputTargetComponent())
        entity.generateCollisionShapes(recursive: true)

        anchor.addChild(entity)
        iconEntity = entity

        print(
            """
            [TuringDoorTrigger] icon installed
              anchor: \(anchor.name)
              component: TuringStoryDoorTriggerComponent
              target: \(TuringScriptTriggerTarget.storyDoor.rawValue)
              style: posterSticker
            """
        )
    }

    func remove() {
        iconEntity?.removeFromParent()
        iconEntity = nil
    }

    private func makeIconMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        if let texture = try? makeIconTexture() {
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
        material.faceCulling = .none
        return material
    }

    private func makeIconTexture() throws -> TextureResource {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let stroke = UIColor.white.withAlphaComponent(0.95)
            stroke.setStroke()

            let lineWidth: CGFloat = 18
            let frameRect = CGRect(x: 72, y: 42, width: 112, height: 174)
            let panelRect = CGRect(x: 92, y: 62, width: 72, height: 134)

            let framePath = UIBezierPath(rect: frameRect)
            framePath.lineWidth = lineWidth
            framePath.stroke()

            let panelPath = UIBezierPath(rect: panelRect)
            panelPath.lineWidth = 12
            panelPath.stroke()

            let knobPath = UIBezierPath(
                ovalIn: CGRect(
                    x: 142,
                    y: 126,
                    width: 13,
                    height: 13
                )
            )
            stroke.setFill()
            knobPath.fill()
        }

        return try TextureResource(
            image: image.cgImage!,
            withName: "turing_story_door_sticker",
            options: .init(
                semantic: .color
            )
        )
    }
}
