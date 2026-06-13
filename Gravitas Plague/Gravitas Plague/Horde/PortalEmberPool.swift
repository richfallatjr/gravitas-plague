import Foundation
import RealityKit
import simd

struct PortalEmber {
    var entity: ModelEntity
    var active: Bool = false

    var age: Float = 0
    var life: Float = 1.8

    var position: SIMD3<Float> = .zero
    var velocity: SIMD3<Float> = .zero

    var startSize: Float = 0.008
    var endSize: Float = 0.003

    var birthMaterialIndex: Int = 0
    var hotMaterialIndex: Int = 0
    var redMaterialIndex: Int = 0
    var darkMaterialIndex: Int = 0

    var spinRadiansPerSecond: Float = 0
}

@MainActor
final class PortalEmberPool {
    private let root: Entity
    private var embers: [PortalEmber] = []
    private var nextIndex: Int = 0

    init(
        root: Entity,
        maxActive: Int
    ) {
        self.root = root

        let resources = PortalFXSharedResources.shared

        embers.reserveCapacity(maxActive)

        for index in 0..<maxActive {
            let entity = ModelEntity(
                mesh: resources.emberMesh,
                materials: [resources.emberDarkMaterials[0]]
            )

            entity.name = "PortalEmber_\(index)"
            entity.isEnabled = false
            entity.scale = SIMD3<Float>(
                repeating: PortalFXDefaults.emberStartSizeMetersMax
            )

            root.addChild(entity)

            embers.append(
                PortalEmber(entity: entity)
            )
        }

        print(
            """
            [PortalEmberPool] created
              maxActive: \(maxActive)
            """
        )
    }

    func spawn(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        life: Float
    ) {
        guard !embers.isEmpty else {
            return
        }

        let resources = PortalFXSharedResources.shared
        let index = nextIndex
        nextIndex = (nextIndex + 1) % embers.count

        var ember = embers[index]

        ember.active = true
        ember.age = 0
        ember.life = life
        ember.position = position
        ember.velocity = velocity
        ember.startSize = Float.random(
            in: PortalFXDefaults.emberStartSizeMetersMin...PortalFXDefaults.emberStartSizeMetersMax
        )
        ember.endSize = Float.random(
            in: PortalFXDefaults.emberEndSizeMetersMin...PortalFXDefaults.emberEndSizeMetersMax
        )

        ember.birthMaterialIndex = Int.random(
            in: 0..<resources.emberBirthMaterials.count
        )
        ember.hotMaterialIndex = Int.random(
            in: 0..<resources.emberHotMaterials.count
        )
        ember.redMaterialIndex = Int.random(
            in: 0..<resources.emberRedMaterials.count
        )
        ember.darkMaterialIndex = Int.random(
            in: 0..<resources.emberDarkMaterials.count
        )
        ember.spinRadiansPerSecond = Float.random(in: -4.0...4.0)

        ember.entity.position = position
        ember.entity.scale = SIMD3<Float>(
            repeating: ember.startSize
        )
        ember.entity.model?.materials = [
            resources.emberBirthMaterials[ember.birthMaterialIndex]
        ]
        ember.entity.isEnabled = true

        embers[index] = ember
    }

    func update(
        deltaTime: Float
    ) {
        let resources = PortalFXSharedResources.shared

        for index in embers.indices {
            guard embers[index].active else {
                continue
            }

            embers[index].age += deltaTime

            let t = embers[index].age / max(
                embers[index].life,
                0.001
            )

            if t >= 1 {
                embers[index].active = false
                embers[index].entity.isEnabled = false
                continue
            }

            embers[index].velocity.y += 0.18 * deltaTime
            embers[index].position += embers[index].velocity * deltaTime
            embers[index].entity.position = embers[index].position

            let spin = embers[index].spinRadiansPerSecond * deltaTime
            embers[index].entity.orientation =
                simd_quatf(
                    angle: spin,
                    axis: SIMD3<Float>(0, 1, 0)
                ) * embers[index].entity.orientation

            let size = mix(
                embers[index].startSize,
                embers[index].endSize,
                t
            )

            embers[index].entity.scale = SIMD3<Float>(
                repeating: size
            )

            switch t {
            case ..<0.18:
                embers[index].entity.model?.materials = [
                    resources.emberBirthMaterials[embers[index].birthMaterialIndex]
                ]

            case ..<0.50:
                embers[index].entity.model?.materials = [
                    resources.emberHotMaterials[embers[index].hotMaterialIndex]
                ]

            case ..<0.84:
                embers[index].entity.model?.materials = [
                    resources.emberRedMaterials[embers[index].redMaterialIndex]
                ]

            default:
                embers[index].entity.model?.materials = [
                    resources.emberDarkMaterials[embers[index].darkMaterialIndex]
                ]
            }
        }
    }

    func setEnabled(
        _ enabled: Bool
    ) {
        root.isEnabled = enabled
    }

    func teardown() {
        root.children.removeAll()
        embers.removeAll()
    }

    private func mix(
        _ a: Float,
        _ b: Float,
        _ t: Float
    ) -> Float {
        a + (b - a) * t
    }
}
