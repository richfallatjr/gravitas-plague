import RealityKit
import UIKit
import simd

@MainActor
final class TuringStoryCrankRadioIconController {
    private static let visualSize =
        WallStickerStyle.stickerSizeMeters * 0.5
    private static let hitTargetSize =
        WallStickerStyle.stickerSizeMeters

    private var iconEntity: ModelEntity?
    private var physicalHitTarget: Entity?
    private var cachedMaterials:
        [String: UnlitMaterial] = [:]

    func install(
        iconAnchor: Entity,
        crankRadioRoot: Entity
    ) {
        remove()
        TuringStoryCrankRadioActionComponents
            .registerIfNeeded()

        let icon = ModelEntity(
            mesh: .generatePlane(
                width: Self.visualSize,
                height: Self.visualSize
            ),
            materials: [
                material(symbolName: "play.circle")
            ]
        )
        icon.name =
            "TuringStoryCrankRadio_ActionIcon"
        icon.position = .zero
        icon.orientation = simd_quatf(
            angle: Float.pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
        )
        icon.components.set(InputTargetComponent())
        icon.components.set(
            CollisionComponent(
                shapes: [
                    .generateBox(
                        size: SIMD3<Float>(
                            Self.hitTargetSize,
                            Self.hitTargetSize,
                            0.012
                        )
                    )
                ]
            )
        )

        let physicalTarget =
            makePhysicalHitTarget(
                crankRadioRoot: crankRadioRoot
            )
        iconAnchor.addChild(icon)

        let worldMatrix =
            icon.transformMatrix(relativeTo: nil)
        let inheritedWorldScale = max(
            simd_length(
                SIMD3<Float>(
                    worldMatrix.columns.0.x,
                    worldMatrix.columns.0.y,
                    worldMatrix.columns.0.z
                )
            ),
            simd_length(
                SIMD3<Float>(
                    worldMatrix.columns.1.x,
                    worldMatrix.columns.1.y,
                    worldMatrix.columns.1.z
                )
            ),
            simd_length(
                SIMD3<Float>(
                    worldMatrix.columns.2.x,
                    worldMatrix.columns.2.y,
                    worldMatrix.columns.2.z
                )
            )
        )
        let bottomAlignmentOffset =
            Self.visualSize *
            inheritedWorldScale *
            0.5
        let anchorWorldPosition =
            iconAnchor.position(relativeTo: nil)
        icon.setPosition(
            anchorWorldPosition +
                SIMD3<Float>(
                    0,
                    bottomAlignmentOffset,
                    0
                ),
            relativeTo: nil
        )

        iconEntity = icon
        physicalHitTarget = physicalTarget
        apply(.hidden)

        print("""
        [TuringCrankRadio] action targets installed
          iconAnchor: \(iconAnchor.name)
          crankRadioRoot: \(crankRadioRoot.name)
          physicalTarget: \(physicalTarget.name)
          visualSizeMeters: \(Self.visualSize)
          anchorAlignment: world_up_bottom_center
        """)
    }

    func apply(
        _ presentation:
            StoryCrankRadioPresentation,
        activity: StoryTuringActivityPresentation = .hidden,
        microphoneCTAEmphasis: StoryMicrophoneCTAEmphasis = .saturated
    ) {
        guard let iconEntity,
              let physicalHitTarget else {
            return
        }
        removeActionComponents(from: iconEntity)
        removeActionComponents(
            from: physicalHitTarget
        )

        switch presentation {
        case .hidden:
            switch activity {
            case .authoredPlaying, .conversationPlaying:
                updateIcon(symbolName: "play.fill", on: iconEntity)
                iconEntity.isEnabled = true
            case .processingEllipsis:
                updateIcon(symbolName: "ellipsis", on: iconEntity)
                iconEntity.isEnabled = true
            case .hidden:
                iconEntity.isEnabled = false
            }
            physicalHitTarget.isEnabled = false

        case .play:
            updateIcon(
                symbolName: "play.circle",
                on: iconEntity
            )
            iconEntity.components.set(
                TuringStoryCrankRadioPlayComponent()
            )
            physicalHitTarget.components.set(
                TuringStoryCrankRadioPlayComponent()
            )
            iconEntity.isEnabled = true
            physicalHitTarget.isEnabled = true

        case .microphone:
            updateIcon(
                symbolName: "mic.circle",
                microphoneCTAEmphasis: microphoneCTAEmphasis,
                on: iconEntity
            )
            iconEntity.components.set(
                TuringStoryCrankRadioMicrophoneComponent()
            )
            physicalHitTarget.components.set(
                TuringStoryCrankRadioMicrophoneComponent()
            )
            iconEntity.isEnabled = true
            physicalHitTarget.isEnabled = true
        case .microphoneRecovering, .microphoneUnavailable:
            updateIcon(
                symbolName: "mic.circle",
                microphoneCTAEmphasis: .desaturated,
                on: iconEntity
            )
            iconEntity.isEnabled = true
            physicalHitTarget.isEnabled = false
        }
    }

    func remove() {
        if let iconEntity {
            removeActionComponents(
                from: iconEntity
            )
        }
        if let physicalHitTarget {
            removeActionComponents(
                from: physicalHitTarget
            )
        }
        iconEntity?.removeFromParent()
        physicalHitTarget?.removeFromParent()
        iconEntity = nil
        physicalHitTarget = nil
    }

    private func makePhysicalHitTarget(
        crankRadioRoot: Entity
    ) -> Entity {
        let bounds =
            crankRadioRoot.visualBounds(
                recursive: true,
                relativeTo: crankRadioRoot,
                excludeInactive: false
            )
        let size = SIMD3<Float>(
            max(bounds.extents.x, 0.10),
            max(bounds.extents.y, 0.08),
            max(bounds.extents.z, 0.06)
        )
        let target = Entity()
        target.name =
            "TuringStoryCrankRadio_PhysicalHitTarget"
        target.position = bounds.center
        target.components.set(InputTargetComponent())
        target.components.set(
            CollisionComponent(
                shapes: [
                    .generateBox(size: size)
                ]
            )
        )
        crankRadioRoot.addChild(target)
        return target
    }

    private func removeActionComponents(
        from entity: Entity
    ) {
        entity.components.remove(
            TuringStoryCrankRadioPlayComponent.self
        )
        entity.components.remove(
            TuringStoryCrankRadioMicrophoneComponent.self
        )
    }

    private func updateIcon(
        symbolName: String,
        microphoneCTAEmphasis: StoryMicrophoneCTAEmphasis = .saturated,
        on icon: ModelEntity
    ) {
        guard var model =
                icon.components[ModelComponent.self] else {
            return
        }
        model.materials = [
            material(
                symbolName: symbolName,
                microphoneCTAEmphasis: microphoneCTAEmphasis
            )
        ]
        icon.components.set(model)
    }

    private func material(
        symbolName: String,
        microphoneCTAEmphasis: StoryMicrophoneCTAEmphasis = .saturated
    ) -> UnlitMaterial {
        let cacheKey = "\(symbolName).\(microphoneCTAEmphasis.rawValue)"
        if let cached =
            cachedMaterials[cacheKey] {
            return cached
        }
        let material = (try? TuringStoryActionIconVisualStyle.material(
            symbolName: symbolName,
            microphoneCTAEmphasis: microphoneCTAEmphasis
        )) ?? fallbackMaterial()
        if microphoneCTAEmphasis.isEndpoint {
            cachedMaterials[cacheKey] = material
        }
        return material
    }

    private func fallbackMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .orange)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.92))
        material.faceCulling = .none
        return material
    }

    private func symbolTexture(
        symbolName: String
    ) throws -> TextureResource {
        let configuration =
            UIImage.SymbolConfiguration(
                pointSize: 190,
                weight: .semibold
            )
        guard let symbol = UIImage(
            systemName: symbolName,
            withConfiguration: configuration
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to render crank-radio icon \(symbolName)."
            )
        }
        let size = CGSize(
            width: 256,
            height: 256
        )
        let renderer =
            UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(
                CGRect(origin: .zero, size: size)
            )
            let tinted = symbol.withTintColor(
                .white,
                renderingMode: .alwaysOriginal
            )
            let scale = min(
                220 / max(1, tinted.size.width),
                220 / max(1, tinted.size.height)
            )
            let drawSize = CGSize(
                width: tinted.size.width * scale,
                height: tinted.size.height * scale
            )
            tinted.draw(
                in: CGRect(
                    x:
                        (size.width -
                            drawSize.width) * 0.5,
                    y:
                        (size.height -
                            drawSize.height) * 0.5,
                    width: drawSize.width,
                    height: drawSize.height
                )
            )
        }
        guard let cgImage = image.cgImage else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to rasterize crank-radio icon \(symbolName)."
            )
        }
        return try TextureResource(
            image: cgImage,
            withName:
                "turing_crank_radio_\(symbolName)",
            options: .init(semantic: .color)
        )
    }
}
