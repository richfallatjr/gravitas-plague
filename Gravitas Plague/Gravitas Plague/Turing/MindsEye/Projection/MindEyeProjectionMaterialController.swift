import Foundation
import RealityKit

@MainActor
final class MindEyeProjectionMaterialController {
    private final class Binding {
        weak var entity: Entity?
        let entityPath: String
        let materialIndex: Int
        let originalMaterial: any Material

        init(
            entity: Entity,
            entityPath: String,
            materialIndex: Int,
            originalMaterial: any Material
        ) {
            self.entity = entity
            self.entityPath = entityPath
            self.materialIndex = materialIndex
            self.originalMaterial = originalMaterial
        }
    }

    private enum State {
        case idle
        case installed([Binding])
        case released
    }

    private var state: State = .idle
    private(set) var appliedMaterialCount = 0

    func commit(_ preparation: MindEyeProjectionMaterialPreparation) throws {
        guard case .idle = state else {
            throw MindEyeProjectionError.materialApplicationFailed(
                "material controller was already committed or released"
            )
        }

        var installed: [Binding] = []
        installed.reserveCapacity(preparation.targets.count)
        do {
            for target in preparation.targets {
                guard var model = target.entity.components[ModelComponent.self],
                      model.materials.indices.contains(target.materialIndex) else {
                    throw MindEyeProjectionError.materialApplicationFailed(
                        "target material disappeared before atomic commit: \(target.entityPath)"
                    )
                }
                installed.append(
                    Binding(
                        entity: target.entity,
                        entityPath: target.entityPath,
                        materialIndex: target.materialIndex,
                        originalMaterial: target.originalMaterial
                    )
                )
                model.materials[target.materialIndex] = target.replacement
                target.entity.components.set(model)
            }
        } catch {
            Self.restore(installed)
            throw error
        }

        state = .installed(installed)
        appliedMaterialCount = installed.count
        print(
            "[MindEyeProjection] mesh materials installed " +
                "count=\(installed.count) targetPaths=" +
                installed.map(\.entityPath).joined(separator: ",")
        )
    }

    func release(reason: String = "release") {
        let restoredBindings: [Binding]
        switch state {
        case .idle:
            restoredBindings = []
        case .installed(let bindings):
            Self.restore(bindings)
            restoredBindings = bindings
        case .released:
            return
        }
        state = .released
        if !restoredBindings.isEmpty {
            print(
                "[MindEyeProjection] mesh materials restored " +
                    "count=\(restoredBindings.count) reason=\(reason)"
            )
        }
        appliedMaterialCount = 0
    }

    private static func restore(_ bindings: [Binding]) {
        for binding in bindings {
            guard let entity = binding.entity,
                  var model = entity.components[ModelComponent.self],
                  model.materials.indices.contains(binding.materialIndex) else {
                continue
            }
            model.materials[binding.materialIndex] = binding.originalMaterial
            entity.components.set(model)
        }
    }
}
