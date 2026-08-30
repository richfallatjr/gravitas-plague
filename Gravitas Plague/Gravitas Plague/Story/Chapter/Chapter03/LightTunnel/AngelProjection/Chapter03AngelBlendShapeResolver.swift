import RealityKit

@MainActor
struct Chapter03AngelBlendShapeResolver {
    func resolve(
        in root: Entity,
        targetName: String
    ) throws -> [Chapter03AngelBlendShapeBinding] {
        var bindings: [Chapter03AngelBlendShapeBinding] = []
        try visit(
            entity: root,
            path: root.name,
            targetName: targetName,
            bindings: &bindings
        )
        guard !bindings.isEmpty else {
            throw Chapter03AngelBlendShapeError.targetNotFound(targetName)
        }
        return bindings
    }

    private func visit(
        entity: Entity,
        path: String,
        targetName: String,
        bindings: inout [Chapter03AngelBlendShapeBinding]
    ) throws {
        if let model = entity as? ModelEntity {
            let names = model.blendWeightNames
            let weights = model.blendWeights
            guard names.count == weights.count else {
                throw Chapter03AngelBlendShapeError.groupCountMismatch(
                    entityPath: path
                )
            }
            for groupIndex in names.indices {
                guard names[groupIndex].count == weights[groupIndex].count else {
                    throw Chapter03AngelBlendShapeError.weightCountMismatch(
                        entityPath: path,
                        groupIndex: groupIndex
                    )
                }
                let indices = names[groupIndex].indices.filter {
                    names[groupIndex][$0] == targetName
                }
                guard indices.count <= 1 else {
                    throw Chapter03AngelBlendShapeError.duplicateTarget(
                        entityPath: path,
                        groupIndex: groupIndex
                    )
                }
                if let weightIndex = indices.first {
                    bindings.append(
                        Chapter03AngelBlendShapeBinding(
                            entity: model,
                            entityPath: path,
                            groupIndex: groupIndex,
                            weightIndex: weightIndex,
                            weightName: targetName,
                            originalWeightGroups: weights
                        )
                    )
                }
            }
        }
        for child in entity.children {
            try visit(
                entity: child,
                path: path + "/" + child.name,
                targetName: targetName,
                bindings: &bindings
            )
        }
    }
}
