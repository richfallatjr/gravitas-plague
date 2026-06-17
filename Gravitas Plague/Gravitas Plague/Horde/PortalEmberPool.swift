import Foundation
import RealityKit
import simd

private enum PortalEmberMaterialPhase: Sendable {
    case birth
    case hot
    case red
    case dark
}

private struct PortalEmberFrameUpdate: Sendable {
    let index: Int
    let active: Bool
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let size: Float
    let materialPhase: PortalEmberMaterialPhase
    let materialIndex: Int
}

private struct PortalEmberFrameOutput: Sendable {
    let updates: [PortalEmberFrameUpdate]
}

struct PortalEmber {
    var entity: ModelEntity
    var active: Bool = false

    var age: Float = 0
    var life: Float = 1.8

    var position: SIMD3<Float> = .zero
    var velocity: SIMD3<Float> = .zero
    var orientation = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )

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

    var activeCount: Int {
        embers.reduce(0) { partialResult, ember in
            partialResult + (ember.active ? 1 : 0)
        }
    }

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
        ember.orientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
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
        ember.entity.orientation = ember.orientation
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
        let output = step(
            deltaTime: deltaTime
        )

        apply(
            output
        )
    }

    func update(
        deltaTime: Float,
        timingProfiler: TimingProfiler?
    ) {
        if let timingProfiler {
            let output = timingProfiler.measure("portal.ember.step") {
                step(
                    deltaTime: deltaTime
                )
            }

            timingProfiler.measure("portal.ember.apply") {
                apply(
                    output
                )
            }
        } else {
            update(
                deltaTime: deltaTime
            )
        }
    }

    private func step(
        deltaTime: Float
    ) -> PortalEmberFrameOutput {
        var updates: [PortalEmberFrameUpdate] = []

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
                updates.append(
                    PortalEmberFrameUpdate(
                        index: index,
                        active: false,
                        position: embers[index].position,
                        orientation: embers[index].orientation,
                        size: embers[index].endSize,
                        materialPhase: .dark,
                        materialIndex: embers[index].darkMaterialIndex
                    )
                )
                continue
            }

            embers[index].velocity.y += 0.18 * deltaTime
            embers[index].position += embers[index].velocity * deltaTime

            let spin = embers[index].spinRadiansPerSecond * deltaTime
            embers[index].orientation =
                simd_quatf(
                    angle: spin,
                    axis: SIMD3<Float>(0, 1, 0)
                ) * embers[index].orientation

            let size = mix(
                embers[index].startSize,
                embers[index].endSize,
                t
            )

            let material = materialPhaseAndIndex(
                for: embers[index],
                normalizedAge: t
            )

            updates.append(
                PortalEmberFrameUpdate(
                    index: index,
                    active: true,
                    position: embers[index].position,
                    orientation: embers[index].orientation,
                    size: size,
                    materialPhase: material.phase,
                    materialIndex: material.index
                )
            )
        }

        return PortalEmberFrameOutput(
            updates: updates
        )
    }

    private func apply(
        _ output: PortalEmberFrameOutput
    ) {
        let resources = PortalFXSharedResources.shared

        for update in output.updates {
            guard embers.indices.contains(update.index) else {
                continue
            }

            let entity = embers[update.index].entity

            guard update.active else {
                entity.isEnabled = false
                continue
            }

            entity.position = update.position
            entity.orientation = update.orientation
            entity.scale = SIMD3<Float>(
                repeating: update.size
            )
            entity.model?.materials = [
                material(
                    resources: resources,
                    phase: update.materialPhase,
                    index: update.materialIndex
                )
            ]
            entity.isEnabled = true
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

    private func materialPhaseAndIndex(
        for ember: PortalEmber,
        normalizedAge t: Float
    ) -> (phase: PortalEmberMaterialPhase, index: Int) {
        switch t {
        case ..<0.18:
            return (.birth, ember.birthMaterialIndex)
        case ..<0.50:
            return (.hot, ember.hotMaterialIndex)
        case ..<0.84:
            return (.red, ember.redMaterialIndex)
        default:
            return (.dark, ember.darkMaterialIndex)
        }
    }

    private func material(
        resources: PortalFXSharedResources,
        phase: PortalEmberMaterialPhase,
        index: Int
    ) -> RealityKit.Material {
        switch phase {
        case .birth:
            return material(
                in: resources.emberBirthMaterials,
                at: index
            )
        case .hot:
            return material(
                in: resources.emberHotMaterials,
                at: index
            )
        case .red:
            return material(
                in: resources.emberRedMaterials,
                at: index
            )
        case .dark:
            return material(
                in: resources.emberDarkMaterials,
                at: index
            )
        }
    }

    private func material(
        in materials: [RealityKit.Material],
        at index: Int
    ) -> RealityKit.Material {
        guard materials.indices.contains(index) else {
            return materials[0]
        }

        return materials[index]
    }
}
