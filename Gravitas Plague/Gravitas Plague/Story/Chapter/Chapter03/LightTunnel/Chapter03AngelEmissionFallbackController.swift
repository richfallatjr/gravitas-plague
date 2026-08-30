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

    func setProjectionOwnsEmission(_ active: Bool, reason: String) {
        guard projectionOwnsEmission != active else { return }
        projectionOwnsEmission = active
        transitionCount &+= 1

        var suppressed = 0
        var restored = 0
        var projectionMaterialsRetained = 0
        for binding in bindings {
            guard let entity = binding.entity,
                  var model = entity.components[ModelComponent.self],
                  model.materials.indices.contains(binding.materialIndex) else {
                continue
            }
            if active {
                if var pbr = model.materials[binding.materialIndex]
                    as? PhysicallyBasedMaterial {
                    pbr.emissiveIntensity = 0
                    model.materials[binding.materialIndex] = pbr
                    entity.components.set(model)
                    suppressed += 1
                } else {
                    // A live projection ShaderGraph material already owns this
                    // slot, so replacing it here would destroy the projection.
                    projectionMaterialsRetained += 1
                }
            } else {
                // Projection failure is fail-soft and deterministic: restore
                // the captured PBR material, including its texture and the
                // normalized fallback intensity installed at scene load.
                model.materials[binding.materialIndex] = binding.fallbackMaterial
                entity.components.set(model)
                restored += 1
            }
        }
        print(
            "[Chapter03AngelEmission] ownership changed " +
                "projectionOwnsEmission=\(active) reason=\(reason) " +
                "suppressed=\(suppressed) restored=\(restored) " +
                "projectionMaterialsRetained=\(projectionMaterialsRetained) " +
                "transitionCount=\(transitionCount)"
        )
    }

    func restoreFallback(reason: String) {
        if projectionOwnsEmission {
            setProjectionOwnsEmission(false, reason: reason)
            return
        }
        // Teardown can follow a partially installed or failed projection before
        // readiness changes. Reassert the saved PBR slots even in that case.
        for binding in bindings {
            guard let entity = binding.entity,
                  var model = entity.components[ModelComponent.self],
                  model.materials.indices.contains(binding.materialIndex) else {
                continue
            }
            model.materials[binding.materialIndex] = binding.fallbackMaterial
            entity.components.set(model)
        }
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
