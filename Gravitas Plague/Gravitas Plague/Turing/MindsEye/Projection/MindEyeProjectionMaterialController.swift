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

    private var bindings: [Binding] = []
    private(set) var appliedMaterialCount = 0

    func apply(
        _ materials: [ShaderGraphMaterial],
        to resolution: MindEyeProjectionTargetResolver.Resolution
    ) throws {
        guard bindings.isEmpty,
              materials.count == resolution.materials.count else {
            throw MindEyeProjectionError.materialApplicationFailed(
                "projection material count does not match the exact target resolution"
            )
        }

        var installed: [Binding] = []
        do {
            for (index, resolved) in resolution.materials.enumerated() {
                guard var model = resolved.entity.components[ModelComponent.self],
                      model.materials.indices.contains(resolved.materialIndex) else {
                    throw MindEyeProjectionError.materialApplicationFailed(
                        "target material disappeared before installation: \(resolved.entityPath)"
                    )
                }
                installed.append(
                    Binding(
                        entity: resolved.entity,
                        entityPath: resolved.entityPath,
                        materialIndex: resolved.materialIndex,
                        originalMaterial: model.materials[resolved.materialIndex]
                    )
                )
                model.materials[resolved.materialIndex] = materials[index]
                resolved.entity.components.set(model)
            }
        } catch {
            Self.restore(installed)
            throw error
        }

        bindings = installed
        appliedMaterialCount = installed.count
        print(
            "[MindEyeProjection] mesh materials installed " +
                "count=\(installed.count) targetPaths=" +
                installed.map(\.entityPath).joined(separator: ",")
        )
    }

    func release(reason: String = "release") {
        Self.restore(bindings)
        if !bindings.isEmpty {
            print(
                "[MindEyeProjection] mesh materials restored " +
                    "count=\(bindings.count) reason=\(reason)"
            )
        }
        bindings.removeAll(keepingCapacity: false)
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
