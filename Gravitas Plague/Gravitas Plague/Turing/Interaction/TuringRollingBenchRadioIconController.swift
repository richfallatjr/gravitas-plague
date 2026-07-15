import RealityKit
import UIKit
import simd

@MainActor
final class TuringRollingBenchRadioIconController {
    private static let visualSize = WallStickerStyle.stickerSizeMeters * 0.5
    private static let hitTargetSize = WallStickerStyle.stickerSizeMeters

    private var icon: ModelEntity?
    private var physicalHitTarget: Entity?
    private var cachedMaterials: [String: UnlitMaterial] = [:]

    func install(
        iconAnchor: Entity,
        crankRadioRoot: Entity,
        initialState: TuringRollingBenchRadioController.State
    ) {
        remove()
        TuringRollingBenchDeviceComponents.registerIfNeeded()

        let size = Self.visualSize
        let icon = ModelEntity(
            mesh: .generatePlane(width: size, height: size),
            materials: [material(symbolName: "play.circle")]
        )
        icon.name = TuringRollingBenchEntityName.runtimeCrankRadioActionIcon
        icon.position = .zero
        icon.orientation = simd_quatf(
            angle: Float.pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
        )
        installAction(on: icon)
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
        let physicalTarget = makePhysicalHitTarget(
            crankRadioRoot: crankRadioRoot
        )
        iconAnchor.addChild(icon)

        let worldMatrix = icon.transformMatrix(relativeTo: nil)
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
        let worldBottomAlignmentOffset = size * inheritedWorldScale * 0.5
        let anchorWorldPosition = iconAnchor.position(relativeTo: nil)
        let iconWorldPosition = anchorWorldPosition + SIMD3<Float>(
            0,
            worldBottomAlignmentOffset,
            0
        )
        icon.setPosition(iconWorldPosition, relativeTo: nil)

        self.icon = icon
        self.physicalHitTarget = physicalTarget
        apply(initialState)

        print(
            """
            [TuringRollingBenchRadio] interaction installed
              iconAnchor: \(iconAnchor.name)
              physicalTargetParent: \(crankRadioRoot.name)
              component: TuringRollingBenchDeviceActionComponent
              style: wallSticker
              visualSizeMeters: \(size)
              hitTargetSizeMeters: \(Self.hitTargetSize)
              anchorAlignment: world_up_bottom_center
              inheritedWorldScale: \(inheritedWorldScale)
              worldBottomAlignmentOffset: \(worldBottomAlignmentOffset)
              anchorWorldPosition: \(anchorWorldPosition)
              iconWorldPosition: \(iconWorldPosition)
            """
        )
    }

    func apply(_ state: TuringRollingBenchRadioController.State) {
        switch state {
        case .unavailable:
            icon?.isEnabled = false
            physicalHitTarget?.isEnabled = false
        case .stopped:
            updateIcon(symbolName: "play.circle")
            icon?.isEnabled = true
            physicalHitTarget?.isEnabled = true
        case .playing:
            updateIcon(symbolName: "pause.circle")
            icon?.isEnabled = true
            physicalHitTarget?.isEnabled = true
        }
        print("[TuringRollingBenchRadio] icon state=\(state.rawValue)")
    }

    func remove() {
        icon?.removeFromParent()
        physicalHitTarget?.removeFromParent()
        icon = nil
        physicalHitTarget = nil
    }

    private func installAction(on entity: Entity) {
        entity.components.set(InputTargetComponent())
        entity.components.set(
            TuringRollingBenchDeviceActionComponent(
                deviceID: .crankRadio,
                action: .togglePlayback
            )
        )
    }

    private func makePhysicalHitTarget(crankRadioRoot: Entity) -> Entity {
        let bounds = crankRadioRoot.visualBounds(
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
        target.name = TuringRollingBenchEntityName.runtimeCrankRadioHitTarget
        target.position = bounds.center
        installAction(on: target)
        target.components.set(
            CollisionComponent(shapes: [.generateBox(size: size)])
        )
        crankRadioRoot.addChild(target)
        return target
    }

    private func updateIcon(symbolName: String) {
        guard let icon,
              var model = icon.components[ModelComponent.self] else {
            return
        }
        model.materials = [material(symbolName: symbolName)]
        icon.components.set(model)
    }

    private func material(symbolName: String) -> UnlitMaterial {
        if let cached = cachedMaterials[symbolName] {
            return cached
        }
        var material = UnlitMaterial()
        if let texture = try? symbolTexture(symbolName: symbolName) {
            material.color = .init(
                tint: WallStickerStyle.twoStopsDownTint,
                texture: .init(texture)
            )
        } else {
            material.color = .init(tint: WallStickerStyle.twoStopsDownTint)
        }
        material.blending = .transparent(
            opacity: .init(floatLiteral: 0.92)
        )
        material.faceCulling = .none
        cachedMaterials[symbolName] = material
        return material
    }

    private func symbolTexture(symbolName: String) throws -> TextureResource {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: 190,
            weight: .semibold
        )
        guard let symbol = UIImage(
            systemName: symbolName,
            withConfiguration: configuration
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to render rolling-bench icon \(symbolName)."
            )
        }
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let tinted = symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
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
                    x: (size.width - drawSize.width) * 0.5,
                    y: (size.height - drawSize.height) * 0.5,
                    width: drawSize.width,
                    height: drawSize.height
                )
            )
        }
        guard let cgImage = image.cgImage else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to rasterize rolling-bench icon \(symbolName)."
            )
        }
        return try TextureResource(
            image: cgImage,
            withName: "turing_rolling_bench_\(symbolName)",
            options: .init(semantic: .color)
        )
    }
}
