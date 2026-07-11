import Foundation
import RealityKit
import UIKit
import simd

struct TuringStoryWalkieMicBillboardComponent: Component {
}

extension Notification.Name {
    static let turingStoryWalkieMicHoldBegan =
        Notification.Name("turingStoryWalkieMicHoldBegan")

    static let turingStoryWalkieMicHoldEnded =
        Notification.Name("turingStoryWalkieMicHoldEnded")
}

@MainActor
final class TuringStoryPropBillboardIconController {
    private var micIconEntity: ModelEntity?

    func installWalkieMicIcon(
        anchor: Entity,
        target: TuringScriptTriggerTarget,
        onHoldBegan: @escaping @MainActor () -> Void,
        onHoldEnded: @escaping @MainActor () -> Void
    ) {
        removeWalkieMicIcon()
        TuringStoryWalkieMicBillboardComponent.registerComponent()

        let visualSize = WallStickerStyle.stickerSizeMeters * 0.5
        let icon = ModelEntity(
            mesh: .generatePlane(
                width: visualSize,
                height: visualSize
            ),
            materials: [makeMicrophoneMaterial()]
        )
        icon.name = "TuringStoryWalkieTalkie_MicHitTarget"
        icon.position = .zero
        icon.orientation = simd_quatf(
            angle: Float.pi / 2.0,
            axis: SIMD3<Float>(1, 0, 0)
        )
        icon.components.set(TuringStoryWalkieMicBillboardComponent())
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
        anchor.addChild(icon)
        micIconEntity = icon

        print("""
        [TuringWalkieBundle] mic billboard installed
          anchor: \(anchor.name)
          target: \(target.rawValue)
          icon: mic.circle
          style: doorSticker
          visualSizeMeters: \(visualSize)
          hitTargetSizeMeters: \(WallStickerStyle.stickerSizeMeters)
          axisCorrection: x_plus_90_to_wall_normal
        """)
    }

    func removeWalkieMicIcon() {
        micIconEntity?.removeFromParent()
        micIconEntity = nil
    }

    private func makeMicrophoneMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        if let texture = try? makeMicrophoneTexture() {
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

    private func makeMicrophoneTexture() throws -> TextureResource {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: 190,
            weight: .semibold
        )
        guard let symbol = UIImage(
            systemName: "mic.circle",
            withConfiguration: configuration
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Unable to render the mic.circle Story walkie icon."
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
                "Unable to create the Story walkie microphone texture."
            )
        }

        return try TextureResource(
            image: cgImage,
            withName: "turing_story_walkie_mic_circle_sticker",
            options: .init(semantic: .color)
        )
    }
}
