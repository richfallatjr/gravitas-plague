import RealityKit
import simd
import UIKit

@MainActor
final class HordeEnemyBodyCollisionBox {
    let root = Entity()
    let debugEntity: ModelEntity

    private(set) var enabled = false

    let sizeMeters: SIMD3<Float>
    let centerOffsetMeters: SIMD3<Float>

    init(
        attributes: CharacterBodyCollisionAttributes,
        name: String
    ) {
        self.sizeMeters = attributes.sizeMeters
        self.centerOffsetMeters = attributes.resolvedCenterOffsetMeters

        root.name = "EnemyBodyCollisionBox_\(name)"
        root.position = centerOffsetMeters

        let mesh = MeshResource.generateBox(
            size: sizeMeters
        )

        let material = Self.material(
            color: UIColor.green.withAlphaComponent(0.18)
        )

        debugEntity = ModelEntity(
            mesh: mesh,
            materials: [material]
        )

        debugEntity.name = "EnemyBodyCollisionDebugBox_\(name)"
        debugEntity.components.remove(InputTargetComponent.self)
        debugEntity.components.remove(CollisionComponent.self)

        root.addChild(debugEntity)
        debugEntity.isEnabled = false
    }

    func attach(
        to enemyRoot: Entity
    ) {
        if root.parent !== enemyRoot {
            root.removeFromParent()
            enemyRoot.addChild(root)
        }

        root.position = centerOffsetMeters

        print(
            """
            [EnemyCollision] body box attached
              root: \(enemyRoot.name)
              box: \(root.name)
              sizeMeters: \(sizeMeters)
              centerOffsetMeters: \(centerOffsetMeters)
            """
        )
    }

    func setEnabled(
        _ enabled: Bool
    ) {
        self.enabled = enabled
        root.isEnabled = enabled
    }

    func setDebugVisible(
        _ visible: Bool,
        state: HordeEnemyCollisionState
    ) {
        debugEntity.isEnabled = visible && enabled

        guard debugEntity.isEnabled else {
            return
        }

        let color: UIColor

        switch state {
        case .moving:
            color = UIColor.green.withAlphaComponent(0.22)
        case .blockedIdle:
            color = UIColor.yellow.withAlphaComponent(0.30)
        case .dead:
            color = UIColor.red.withAlphaComponent(0.18)
        }

        debugEntity.model?.materials = [
            Self.material(color: color)
        ]
    }

    private static func material(
        color: UIColor
    ) -> SimpleMaterial {
        var material = SimpleMaterial(
            color: color,
            isMetallic: false
        )

        material.color = .init(tint: color)
        return material
    }
}
