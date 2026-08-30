import Foundation
import RealityKit

nonisolated enum Chapter03AngelBlendShapeError: Error, Sendable, Equatable {
    case invalidDescriptor(String)
    case assetHashMismatch(expected: String, actual: String)
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
}
