import RealityKit
import UIKit

struct TuringStoryExperienceModePosterButtonComponent: Component {}

@MainActor
final class TuringStoryPosterExperienceModeIconController {
    private var iconEntity: ModelEntity?
    private var installedCurrentMode: StoryExperienceMode?

    func install(
        posterContentRoot: Entity,
        posterWidth: Float,
        posterHeight: Float,
        currentMode: StoryExperienceMode
    ) {
        remove()
        let size = min(WallStickerStyle.stickerSizeMeters, posterHeight * 0.105)
        let y = -posterHeight * 0.5 - size * 0.90
        let dayNightX = -posterWidth * 0.5 + size * 0.65
        let x = dayNightX + size + WallStickerStyle.stickerSpacingMeters
        let entity = ModelEntity(
            mesh: .generatePlane(width: size, height: size),
            materials: [material(for: currentMode)]
        )
        entity.name = "WallPosterStoryExperienceMode"
        entity.position = SIMD3<Float>(x, y, 0.018)
        entity.components.set(TuringStoryExperienceModePosterButtonComponent())
        entity.components.set(InputTargetComponent())
        entity.generateCollisionShapes(recursive: true)
        posterContentRoot.addChild(entity)
        iconEntity = entity
        installedCurrentMode = currentMode
        log(currentMode, operation: "installed")
    }

    func update(currentMode: StoryExperienceMode) {
        guard installedCurrentMode != currentMode,
              let iconEntity,
              var model = iconEntity.components[ModelComponent.self] else {
            return
        }
        model.materials = [material(for: currentMode)]
        iconEntity.components.set(model)
        installedCurrentMode = currentMode
        log(currentMode, operation: "updated")
    }

    func setEnabled(_ enabled: Bool) {
        iconEntity?.isEnabled = enabled
    }

    func remove() {
        iconEntity?.removeFromParent()
        iconEntity = nil
        installedCurrentMode = nil
    }

    private func material(for mode: StoryExperienceMode) -> UnlitMaterial {
        var material = UnlitMaterial()
        if let texture = try? texture(symbolName: mode.posterToggleSymbolName) {
            material.color = .init(
                tint: WallStickerStyle.twoStopsDownTint,
                texture: .init(texture)
            )
        } else {
            material.color = .init(tint: WallStickerStyle.twoStopsDownTint)
        }
        material.blending = .transparent(opacity: .init(floatLiteral: 0.92))
        return material
    }

    private func texture(symbolName: String) throws -> TextureResource {
        let configuration = UIImage.SymbolConfiguration(pointSize: 180, weight: .semibold)
        guard let symbol = UIImage(systemName: symbolName, withConfiguration: configuration) else {
            throw TuringRuntimeError.invalidConfig("Unable to render Story mode icon \(symbolName).")
        }
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let tinted = symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
            let scale = min(210 / max(1, tinted.size.width), 210 / max(1, tinted.size.height))
            let drawSize = CGSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
            tinted.draw(in: CGRect(
                x: (size.width - drawSize.width) * 0.5,
                y: (size.height - drawSize.height) * 0.5,
                width: drawSize.width,
                height: drawSize.height
            ))
        }
        return try TextureResource(
            image: image.cgImage!,
            withName: "turing_story_mode_\(symbolName)",
            options: .init(semantic: .color)
        )
    }

    private func log(_ mode: StoryExperienceMode, operation: String) {
        print("[StoryExperienceMode] poster icon \(operation) current=\(mode.rawValue) symbol=\(mode.posterToggleSymbolName) action=\(mode.toggleDestination.rawValue)")
    }
}

