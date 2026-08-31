import Foundation
import RealityKit

/// Gives the photographic facial projection exclusive ownership of Angel glow.
/// The imported texture-backed emission remains the exact visual fallback while
/// projection is unavailable, but is never allowed to add a second glow while
/// the projection material is active.
@MainActor
final class Chapter03AngelEmissionFallbackController {
    private final class Binding {
        weak var entity: Entity?
        let entityName: String
        let materialIndex: Int
        let fallbackMaterial: PhysicallyBasedMaterial

        init(
            entity: Entity,
            materialIndex: Int,
            fallbackMaterial: PhysicallyBasedMaterial
        ) {
            self.entity = entity
            entityName = entity.name
            self.materialIndex = materialIndex
            self.fallbackMaterial = fallbackMaterial
        }
    }

    private var bindings: [Binding]
    private(set) var projectionOwnsEmission = false
    private(set) var transitionCount: UInt64 = 0

    init(root: Entity) throws {
        var captured: [Binding] = []
        Self.visitRecursively(root) { entity in
            guard let model = entity.components[ModelComponent.self] else {
                return
            }
            for (index, material) in model.materials.enumerated() {
                guard let pbr = material as? PhysicallyBasedMaterial,
                      pbr.emissiveColor.texture != nil else {
                    continue
                }
                captured.append(Binding(
                    entity: entity,
                    materialIndex: index,
                    fallbackMaterial: pbr
                ))
            }
        }
        guard !captured.isEmpty else {
            throw Chapter03AngelEmissionError.noEmissivePBRMaterial(
                asset: "runtime Angel",
                materialTypes: []
            )
        }
        bindings = captured
        print(
            "[Chapter03AngelEmission] fallback ownership captured " +
                "bindingCount=\(bindings.count) projectionOwnsEmission=false"
        )
    }

    func projectionMaterialDidInstall(reason: String) {
        guard !projectionOwnsEmission else { return }
        projectionOwnsEmission = true
        transitionCount &+= 1
        print(
            "[Chapter03AngelEmission] projection material owns emission " +
                "reason=\(reason) materialWrites=0 " +
                "transitionCount=\(transitionCount)"
        )
    }

    func restoreFallback(reason: String) {
        let changed = projectionOwnsEmission
        projectionOwnsEmission = false
        if changed { transitionCount &+= 1 }
        var restored = 0
        for binding in bindings {
            guard let entity = binding.entity,
                  var model = entity.components[ModelComponent.self],
                  model.materials.indices.contains(binding.materialIndex) else {
                continue
            }
            model.materials[binding.materialIndex] = binding.fallbackMaterial
            entity.components.set(model)
            restored += 1
        }
        print(
            "[Chapter03AngelEmission] imported PBR fallback restored " +
                "reason=\(reason) restored=\(restored) " +
                "transitionCount=\(transitionCount)"
        )
    }

    private static func visitRecursively(
        _ entity: Entity,
        body: (Entity) -> Void
    ) {
        body(entity)
        for child in entity.children {
            visitRecursively(child, body: body)
        }
    }
}
