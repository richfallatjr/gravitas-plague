import Foundation
import QuartzCore
import RealityKit
import UIKit
import simd

@MainActor
final class YouDiedWorldCardPresenter {
    private weak var worldAnchor: AnchorEntity?
    private var currentCard: Entity?

    func bind(
        worldAnchor: AnchorEntity
    ) {
        self.worldAnchor = worldAnchor
    }

    func show(
        originFromDevice: simd_float4x4,
        textureName: String = "you_died",
        width: Float = 1.0,
        distanceMeters: Float = 1.5
    ) async {
        guard let worldAnchor else {
            print("[YouDied] failed: world anchor unavailable")
            return
        }

        guard let image = UIImage(
            named: textureName,
            in: Bundle.main,
            compatibleWith: nil
        ),
              image.size.width > 0,
              image.size.height > 0 else {
            print("[YouDied] failed: \(textureName).png missing or invalid")
            return
        }

        let texture: TextureResource

        do {
            texture = try await TextureResource.load(
                named: textureName
            )
        } catch {
            print("[YouDied] failed to load texture: \(error.localizedDescription)")
            return
        }

        let aspect = Float(
            image.size.width / image.size.height
        )
        let height = width / max(
            aspect,
            0.001
        )

        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor.white,
            texture: .init(texture)
        )
        material.blending = .transparent(
            opacity: 1.0
        )

        let card = ModelEntity(
            mesh: .generatePlane(
                width: width,
                height: height
            ),
            materials: [material]
        )

        card.name = "YouDiedWorldCard"
        card.isEnabled = false
        makeInert(card)

        currentCard?.removeFromParent()
        currentCard = nil

        let deviceFromCard = simd_float4x4.translation(
            SIMD3<Float>(
                0,
                0,
                -max(0.1, distanceMeters)
            )
        )
        let originFromCard = originFromDevice * deviceFromCard

        worldAnchor.addChild(card)
        card.setTransformMatrix(
            originFromCard,
            relativeTo: nil
        )

        card.isEnabled = true
        currentCard = card

        print(
            """
            [YouDied] world card shown
              distanceFromHeadset: \(distanceMeters)
              parentIsWorldAnchor: \(card.parent === worldAnchor)
              worldPosition: \(card.position(relativeTo: nil))
              followsHeadset: false
              fallbackUsed: false
            """
        )
    }

    func remove() {
        currentCard?.removeFromParent()
        currentCard = nil
    }

    private func makeInert(
        _ entity: Entity
    ) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)

        for child in entity.children {
            makeInert(child)
        }
    }
}

private extension simd_float4x4 {
    static func translation(
        _ translation: SIMD3<Float>
    ) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(
            translation.x,
            translation.y,
            translation.z,
            1
        )

        return matrix
    }
}
