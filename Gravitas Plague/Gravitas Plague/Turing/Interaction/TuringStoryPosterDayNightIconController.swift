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
              size: \(size)
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
        let color: UIColor = atmosphere == .night
            ? UIColor(red: 0.68, green: 0.62, blue: 0.95, alpha: 0.95)
            : UIColor(red: 0.78, green: 0.90, blue: 0.95, alpha: 0.95)

        material.color = .init(
            tint: color
        )
        material.blending = .transparent(
            opacity: 0.92
        )

        return material
    }
}
