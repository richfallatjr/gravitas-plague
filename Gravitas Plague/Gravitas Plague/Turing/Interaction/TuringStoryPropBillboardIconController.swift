import Foundation
import RealityKit
import UIKit
import simd

@MainActor
final class TuringStoryPropBillboardIconController {
    typealias Presentation = TuringStoryWalkiePresentation

    private static let walkieIconWorldUpOffsetMeters: Float = 0.0508

    private var iconEntity: ModelEntity?
    private var physicalHitTarget: Entity?
    private var cachedIconMaterials:
        [String: UnlitMaterial] = [:]

    func install(
        iconAnchor: Entity,
        walkieRoot: Entity
    ) {
        remove()
        TuringStoryWalkieActionComponents.registerIfNeeded()

        let visualSize = WallStickerStyle.stickerSizeMeters * 0.5
        let icon = ModelEntity(
            mesh: .generatePlane(
                width: visualSize,
                height: visualSize
            ),
            materials: [iconMaterial(symbolName: "play.circle")]
        )
        icon.name = "TuringStoryWalkieTalkie_ActionIcon"
        icon.position = .zero
        icon.orientation = simd_quatf(
            angle: Float.pi / 2.0,
            axis: SIMD3<Float>(1, 0, 0)
        )
        icon.components.set(InputTargetComponent())
        icon.components.set(
            CollisionComponent(
                shapes: [
                    .generateBox(
                        size: SIMD3<Float>(
                            WallStickerStyle.stickerSizeMeters,
                            WallStickerStyle.stickerSizeMeters,
                            0.012
                        )
                    )
                ]
            )
        )
        let hitTarget = makePhysicalHitTarget(
            walkieRoot: walkieRoot
        )
        iconAnchor.addChild(icon)
        let anchorWorldPosition = iconAnchor.position(relativeTo: nil)
        icon.setPosition(
            anchorWorldPosition + SIMD3<Float>(
                0,
                Self.walkieIconWorldUpOffsetMeters,
                0
            ),
            relativeTo: nil
        )
        walkieRoot.addChild(hitTarget)

        iconEntity = icon
        physicalHitTarget = hitTarget
        apply(.hidden)

        print("""
        [TuringWalkieState] action targets installed
          iconAnchor: \(iconAnchor.name)
          walkieRoot: \(walkieRoot.name)
          physicalTarget: \(hitTarget.name)
          visualSizeMeters: \(visualSize)
          hitTargetSizeMeters: \(WallStickerStyle.stickerSizeMeters)
          iconWorldUpOffsetMeters: \(Self.walkieIconWorldUpOffsetMeters)
        """)
    }

    func apply(
        _ presentation: Presentation,
        activity: StoryTuringActivityPresentation = .hidden
    ) {
        guard let iconEntity,
              let physicalHitTarget else {
            return
        }

        removeActionComponents(from: iconEntity)
        removeActionComponents(from: physicalHitTarget)

        switch presentation {
        case .hidden:
            switch activity {
            case .authoredPlaying, .conversationPlaying:
                updateIconMaterial(symbolName: "play.fill", on: iconEntity)
                iconEntity.isEnabled = true
            case .processingEllipsis:
                updateIconMaterial(symbolName: "ellipsis", on: iconEntity)
                iconEntity.isEnabled = true
            case .hidden:
                iconEntity.isEnabled = false
            }
            physicalHitTarget.isEnabled = false

        case .play:
            updateIconMaterial(
                symbolName: "play.circle",
                on: iconEntity
            )
            iconEntity.components.set(
                TuringStoryWalkiePlayComponent()
            )
            physicalHitTarget.components.set(
                TuringStoryWalkiePlayComponent()
            )
            iconEntity.isEnabled = true
            physicalHitTarget.isEnabled = true

        case .microphone:
            updateIconMaterial(
                symbolName: "mic.circle",
                on: iconEntity
            )
            iconEntity.components.set(
                TuringStoryWalkieMicrophoneComponent()
            )
            physicalHitTarget.components.set(
                TuringStoryWalkieMicrophoneComponent()
            )
            iconEntity.isEnabled = true
            physicalHitTarget.isEnabled = true
        }
    }

    func remove() {
        if let iconEntity {
            removeActionComponents(from: iconEntity)
        }
        if let physicalHitTarget {
            removeActionComponents(from: physicalHitTarget)
        }
        iconEntity?.removeFromParent()
        physicalHitTarget?.removeFromParent()
        iconEntity = nil
        physicalHitTarget = nil
    }

    private func makePhysicalHitTarget(
        walkieRoot: Entity
    ) -> Entity {
        let bounds = walkieRoot.visualBounds(
            recursive: true,
            relativeTo: walkieRoot,
            excludeInactive: false
        )
        let minimumSize = SIMD3<Float>(0.08, 0.12, 0.05)
        let size = SIMD3<Float>(
            max(bounds.extents.x, minimumSize.x),
            max(bounds.extents.y, minimumSize.y),
            max(bounds.extents.z, minimumSize.z)
        )

        let target = Entity()
        target.name = "TuringStoryWalkieTalkie_PhysicalHitTarget"
        target.position = bounds.center
        target.components.set(InputTargetComponent())
        target.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: size)]
            )
        )
        return target
    }

    private func removeActionComponents(from entity: Entity) {
        entity.components.remove(
            TuringStoryWalkiePlayComponent.self
        )
        entity.components.remove(
            TuringStoryWalkieMicrophoneComponent.self
        )
    }

    private func updateIconMaterial(
        symbolName: String,
        on icon: ModelEntity
    ) {
        guard var model = icon.components[ModelComponent.self] else {
            return
        }
        model.materials = [
            iconMaterial(symbolName: symbolName)
        ]
        icon.components.set(model)
    }

    private func iconMaterial(
        symbolName: String
    ) -> UnlitMaterial {
        if let cached = cachedIconMaterials[symbolName] {
            return cached
        }

        let material = (try? TuringStoryActionIconVisualStyle.material(
            symbolName: symbolName
        )) ?? fallbackIconMaterial()
        cachedIconMaterials[symbolName] = material
        return material
    }

    private func fallbackIconMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .orange)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.92))
        material.faceCulling = .none
        return material
    }

    private func makeSymbolTexture(
        symbolName: String
    ) throws -> TextureResource {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: 190,
            weight: .semibold
        )
        guard let symbol = UIImage(
            systemName: symbolName,
            withConfiguration: configuration
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to render the \(symbolName) Story walkie icon."
            )
        }

        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let tinted = symbol.withTintColor(
                .white,
                renderingMode: .alwaysOriginal
            )
            let symbolSize = tinted.size
            let scale = min(
                220.0 / symbolSize.width,
                220.0 / symbolSize.height
            )
            let drawSize = CGSize(
                width: symbolSize.width * scale,
                height: symbolSize.height * scale
            )
            tinted.draw(
                in: CGRect(
                    x: (size.width - drawSize.width) * 0.5,
                    y: (size.height - drawSize.height) * 0.5,
                    width: drawSize.width,
                    height: drawSize.height
                )
            )
        }

        guard let cgImage = image.cgImage else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to create the Story walkie \(symbolName) texture."
            )
        }

        return try TextureResource(
            image: cgImage,
            withName: "turing_story_walkie_\(symbolName)_sticker",
            options: .init(semantic: .color)
        )
    }
}
