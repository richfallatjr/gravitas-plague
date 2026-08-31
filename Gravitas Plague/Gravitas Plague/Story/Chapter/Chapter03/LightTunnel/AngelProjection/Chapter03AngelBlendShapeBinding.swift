import Foundation
import RealityKit

nonisolated enum Chapter03AngelBlendShapeError: Error, Sendable, Equatable {
    case invalidDescriptor(String)
    case assetHashMismatch(expected: String, actual: String)
    case offsetPayloadHashMismatch(expected: String, actual: String)
    case invalidOffsetPayload(String)
    case meshRepairFailed(String)
    case targetNotFound(String)
    case duplicateTarget(entityPath: String, groupIndex: Int)
    case groupCountMismatch(entityPath: String)
    case weightCountMismatch(entityPath: String, groupIndex: Int)
    case entityReleased(String)
    case staleBinding
}

@MainActor
final class Chapter03AngelBlendShapeBinding {
    weak var entity: ModelEntity?
    let entityPath: String
    let groupIndex: Int
    let weightIndex: Int
    let weightName: String
    let originalWeightGroups: [[Float]]

    init(
        entity: ModelEntity,
        entityPath: String,
        groupIndex: Int,
        weightIndex: Int,
        weightName: String,
        originalWeightGroups: [[Float]]
    ) {
        self.entity = entity
        self.entityPath = entityPath
        self.groupIndex = groupIndex
        self.weightIndex = weightIndex
        self.weightName = weightName
        self.originalWeightGroups = originalWeightGroups
    }

    func setWeight(_ requested: Float) throws {
        guard let entity else {
            throw Chapter03AngelBlendShapeError.entityReleased(entityPath)
        }
        let value = min(1, max(0, requested))

        if var component = entity.components[BlendShapeWeightsComponent.self] {
            var set = component.weightSet
            guard set.indices.contains(groupIndex) else {
                throw Chapter03AngelBlendShapeError.staleBinding
            }
            var data = set[groupIndex]
            var weights = data.weights
            guard weights.indices.contains(weightIndex) else {
                throw Chapter03AngelBlendShapeError.staleBinding
            }
            weights[weightIndex] = value
            data.weights = weights
            set[groupIndex] = data
            component.weightSet = set
            entity.components.set(component)
            return
        }

        var groups = entity.blendWeights
        guard groups.indices.contains(groupIndex),
              groups[groupIndex].indices.contains(weightIndex) else {
            throw Chapter03AngelBlendShapeError.staleBinding
        }
        groups[groupIndex][weightIndex] = value
        entity.blendWeights = groups
    }

    func currentWeight() throws -> Float {
        guard let entity else {
            throw Chapter03AngelBlendShapeError.entityReleased(entityPath)
        }
        if let component = entity.components[BlendShapeWeightsComponent.self] {
            let set = component.weightSet
            guard set.indices.contains(groupIndex) else {
                throw Chapter03AngelBlendShapeError.staleBinding
            }
            let weights = set[groupIndex].weights
            guard weights.indices.contains(weightIndex) else {
                throw Chapter03AngelBlendShapeError.staleBinding
            }
            return weights[weightIndex]
        }
        let groups = entity.blendWeights
        guard groups.indices.contains(groupIndex),
              groups[groupIndex].indices.contains(weightIndex) else {
            throw Chapter03AngelBlendShapeError.staleBinding
        }
        return groups[groupIndex][weightIndex]
    }
}
