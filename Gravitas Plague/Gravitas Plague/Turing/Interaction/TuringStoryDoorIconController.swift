import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class TuringStoryDoorIconController {
    private var iconEntity: ModelEntity?
    private var physicalTargetEntity: Entity?
    private var currentPresentation: TuringStoryDoorInteractionPresentation =
        .hidden
    private let extraBottomLiftMeters: Float = 6.0 * 0.0254

    func install(
        anchor: Entity,
        doorPanel: Entity,
        doorID: String = "storyDoor.primary"
    ) {
        remove()
        TuringStoryDoorTriggerComponent.registerComponent()

        let size = WallStickerStyle.stickerSizeMeters
        let material = makeIconMaterial(presentation: .open)
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
        physicalTargetEntity = makePhysicalTarget(
            doorPanel: doorPanel,
            doorID: doorID
        )
        setPresentation(.hidden)

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
              physicalDoorTarget: \(physicalTargetEntity != nil)
            """
        )
    }

    func setPresentation(
        _ presentation: TuringStoryDoorInteractionPresentation
    ) {
        currentPresentation = presentation
        let enabled = presentation != .hidden
        iconEntity?.isEnabled = enabled
        physicalTargetEntity?.isEnabled = enabled

        if enabled,
           var model = iconEntity?.components[ModelComponent.self] {
            model.materials = [makeIconMaterial(presentation: presentation)]
            iconEntity?.components.set(model)
        }

        print("""
        [TuringDoorTrigger] presentation updated
          presentation: \(String(describing: presentation))
          iconEnabled: \(iconEntity?.isEnabled ?? false)
          physicalTargetEnabled: \(physicalTargetEntity?.isEnabled ?? false)
        """)
    }

    func remove() {
        iconEntity?.removeFromParent()
        iconEntity = nil
        physicalTargetEntity?.removeFromParent()
        physicalTargetEntity = nil
        currentPresentation = .hidden
    }

    private func makePhysicalTarget(
        doorPanel: Entity,
        doorID: String
    ) -> Entity {
        let bounds = doorPanel.visualBounds(
            recursive: true,
            relativeTo: doorPanel,
            excludeInactive: false
        )
        let size = SIMD3<Float>(
            max(0.08, bounds.extents.x),
            max(0.08, bounds.extents.y),
            max(0.04, bounds.extents.z)
        )
        let target = Entity()
        target.name = "TuringStoryDoorPhysicalActionTarget"
        target.position = bounds.center
        target.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: size)]
            )
        )
        target.components.set(InputTargetComponent())
        target.components.set(
            TuringStoryDoorTriggerComponent(
                doorID: doorID
            )
        )
        doorPanel.addChild(target)
        return target
    }

    private func makeIconMaterial(
        presentation: TuringStoryDoorInteractionPresentation
    ) -> UnlitMaterial {
        let symbolName: String
        switch presentation {
        case .open:
            symbolName = "door.left.hand.open"
        case .close:
            symbolName = "door.left.hand.closed"
        case .hidden:
            symbolName = "door.left.hand.closed"
        }
        if let styled = try? TuringStoryActionIconVisualStyle.material(
            symbolName: symbolName
        ) {
            return styled
        }
        var material = UnlitMaterial()
        if let texture = try? makeIconTexture(presentation: presentation) {
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

    private func makeIconTexture(
        presentation: TuringStoryDoorInteractionPresentation
    ) throws -> TextureResource {
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

            if presentation != .hidden {
                let arrowPath = UIBezierPath()
                let points: [CGPoint]
                switch presentation {
                case .open:
                    points = [
                        CGPoint(x: 54, y: 128),
                        CGPoint(x: 96, y: 92),
                        CGPoint(x: 96, y: 164)
                    ]
                case .close:
                    points = [
                        CGPoint(x: 202, y: 128),
                        CGPoint(x: 160, y: 92),
                        CGPoint(x: 160, y: 164)
                    ]
                case .hidden:
                    points = []
                }
                if let first = points.first {
                    arrowPath.move(to: first)
                    for point in points.dropFirst() {
                        arrowPath.addLine(to: point)
                    }
                    arrowPath.close()
                    arrowPath.fill()
                }
            }
        }

        return try TextureResource(
            image: image.cgImage!,
            withName: "turing_story_door_sticker_\(String(describing: presentation))",
            options: .init(
                semantic: .color
            )
        )
    }
}
