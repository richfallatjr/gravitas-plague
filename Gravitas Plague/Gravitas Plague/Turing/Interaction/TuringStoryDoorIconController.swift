import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class TuringStoryDoorIconController {
    private var iconEntity: Entity?
    private let extraBottomLiftMeters: Float = 6.0 * 0.0254

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
        entity.position = .zero
        entity.orientation = simd_quatf(
            angle: Float.pi / 2.0,
            axis: SIMD3<Float>(1, 0, 0)
        )
        entity.components.set(
            TuringStoryDoorTriggerComponent(
                doorID: doorID
            )
        )
        entity.components.set(InputTargetComponent())
        entity.generateCollisionShapes(recursive: true)

        anchor.addChild(entity)

        // The authored icon anchor may be rotated, so its local Y is not
        // necessarily world-up. Position the icon in world space to keep the
        // bottom alignment vertical regardless of the USDZ anchor basis.
        let worldMatrix = entity.transformMatrix(relativeTo: nil)
        let inheritedWorldScale = max(
            simd_length(SIMD3<Float>(
                worldMatrix.columns.0.x,
                worldMatrix.columns.0.y,
                worldMatrix.columns.0.z
            )),
            simd_length(SIMD3<Float>(
                worldMatrix.columns.1.x,
                worldMatrix.columns.1.y,
                worldMatrix.columns.1.z
            )),
            simd_length(SIMD3<Float>(
                worldMatrix.columns.2.x,
                worldMatrix.columns.2.y,
                worldMatrix.columns.2.z
            ))
        )
        let worldOffsetY = size * inheritedWorldScale * 0.5 + extraBottomLiftMeters
        let anchorWorldPosition = anchor.position(relativeTo: nil)
        let iconWorldPosition = anchorWorldPosition + SIMD3<Float>(
            0,
            worldOffsetY,
            0
        )
        entity.setPosition(iconWorldPosition, relativeTo: nil)
        iconEntity = entity

        print(
            """
            [TuringDoorTrigger] icon installed
              anchor: \(anchor.name)
              component: TuringStoryDoorTriggerComponent
              target: \(TuringScriptTriggerTarget.storyDoor.rawValue)
              style: posterSticker
              axisCorrection: x_plus_90_to_wall_normal
              anchorAlignment: world_up_bottom_center_plus_lift
              worldExtraBottomLiftMeters: \(extraBottomLiftMeters)
              inheritedWorldScale: \(inheritedWorldScale)
              worldOffsetY: \(worldOffsetY)
              anchorWorldPosition: \(anchorWorldPosition)
              iconWorldPosition: \(iconWorldPosition)
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
