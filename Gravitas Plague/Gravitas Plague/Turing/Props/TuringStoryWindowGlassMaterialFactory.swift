import RealityKit
import UIKit

enum TuringStoryWindowGlassMaterialFactory {
    @MainActor
    static func makeGlassMaterial() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        let alpha: CGFloat = 0.18

        material.baseColor = .init(
            tint: UIColor(
                red: 0.65,
                green: 0.90,
                blue: 1.0,
                alpha: alpha
            )
        )
        material.metallic = .init(floatLiteral: 0.0)
        material.roughness = .init(floatLiteral: 0.025)
        material.clearcoat = .init(floatLiteral: 0.5)
        material.clearcoatRoughness = .init(floatLiteral: 0.2)
        material.blending = .transparent(opacity: 0.24)
        material.faceCulling = .none

        return material
    }

    @MainActor
    static func applyGlassMaterialRecursively(
        to entity: Entity
    ) {
        let material = makeGlassMaterial()
        applyMaterialRecursively(
            material,
            to: entity
        )
    }

    @MainActor
    private static func applyMaterialRecursively(
        _ material: RealityKit.Material,
        to entity: Entity
    ) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = [material]
            entity.components.set(model)
        }

        for child in entity.children {
            applyMaterialRecursively(
                material,
                to: child
            )
        }
    }
}
