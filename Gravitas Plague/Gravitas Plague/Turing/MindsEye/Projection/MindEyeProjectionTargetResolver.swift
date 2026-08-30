import Foundation
import RealityKit

@MainActor
enum MindEyeProjectionTargetResolver {
    struct ResolvedMaterial {
        let entity: Entity
        let entityPath: String
        let materialIndex: Int
        let material: any Material
    }

    struct Resolution {
        let framingEntity: Entity
        let materials: [ResolvedMaterial]
    }

    static func resolve(
        descriptor: MindEyeProjectionTargetDescriptor,
        subjectRoot: Entity
    ) throws -> Resolution {
        try descriptor.validate()
        guard subjectRoot.name == descriptor.subjectRootEntityName else {
            throw MindEyeProjectionError.targetResolutionFailed(
                "subject root \(subjectRoot.name) != \(descriptor.subjectRootEntityName)"
            )
        }
        let framing = try entity(at: descriptor.framingEntityPath ?? descriptor.targetEntityPath, root: subjectRoot)
        let framingBounds = framing.visualBounds(relativeTo: subjectRoot)
        let framingExtents = framingBounds.max - framingBounds.min
        let hasHeadSizedGeometry = framingExtents.x > 0 && framingExtents.y > 0 && framingExtents.z > 0 &&
            framingExtents.x <= 0.75 && framingExtents.y <= 0.75 && framingExtents.z <= 0.75
        guard descriptor.hasFacialSemanticEvidence || hasHeadSizedGeometry else {
            throw MindEyeProjectionError.targetResolutionFailed(
                "selected target is not face/head geometry: \(descriptor.targetEntityPath) " +
                "has bounds \(framingBounds.min)...\(framingBounds.max). " +
                "The Angel asset must expose a named face/head/skin entity or material, " +
                "or a head-sized framing entity; whole-body projection is forbidden."
            )
        }
        var resolved: [ResolvedMaterial] = []
        for target in descriptor.materials {
            let entity = try entity(at: target.entityPath, root: subjectRoot)
            guard let model = entity.components[ModelComponent.self] else {
                throw MindEyeProjectionError.targetResolutionFailed("\(target.entityPath) has no ModelComponent")
            }
            for (nameIndex, materialIndex) in target.materialIndices.enumerated() {
                guard model.materials.indices.contains(materialIndex) else {
                    throw MindEyeProjectionError.targetResolutionFailed("material index \(materialIndex) is outside \(target.entityPath)")
                }
                let material = model.materials[materialIndex]
                if target.expectedMaterialNames.indices.contains(nameIndex) {
                    let expected = target.expectedMaterialNames[nameIndex]
                    let reflected = String(reflecting: type(of: material))
                    guard expected.isEmpty || reflected.contains(expected) else {
                        throw MindEyeProjectionError.targetResolutionFailed(
                            "material \(materialIndex) type \(reflected) does not contain \(expected)"
                        )
                    }
                }
                resolved.append(ResolvedMaterial(
                    entity: entity,
                    entityPath: target.entityPath,
                    materialIndex: materialIndex,
                    material: material
                ))
            }
        }
        guard resolved.count == descriptor.requiredTargetMaterialCount else {
            throw MindEyeProjectionError.targetResolutionFailed("resolved material count mismatch")
        }
        return Resolution(framingEntity: framing, materials: resolved)
    }

    static func entity(at path: String, root: Entity) throws -> Entity {
        let components = path.split(separator: "/").map(String.init)
        let names = components.first == root.name ? Array(components.dropFirst()) : components
        var current = root
        for name in names where !name.isEmpty {
            guard let child = current.children.first(where: { $0.name == name }) else {
                throw MindEyeProjectionError.targetResolutionFailed("missing entity path \(path) at \(name)")
            }
            current = child
        }
        return current
    }
}
