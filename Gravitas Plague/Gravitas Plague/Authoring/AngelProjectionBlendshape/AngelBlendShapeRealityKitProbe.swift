#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation
import RealityKit

@MainActor
enum AngelBlendShapeRealityKitProbe {
    struct Binding: Sendable, Equatable {
        let entityPath: String
        let groupIndex: Int
        let weightIndex: Int
        let weightName: String
    }

    struct Report: Sendable, Equatable {
        let modelEntityCount: Int
        let bindings: [Binding]
        let testedWeights: [Float]
        let returnedToZero: Bool
    }

    static func run(
        root: Entity,
        targetName: String = "jawOpenProjection"
    ) throws -> Report {
        let resolved = try Chapter03AngelBlendShapeResolver().resolve(
            in: root,
            targetName: targetName
        )
        let weights: [Float] = [0, 0.33, 0.5, 1, 0]
        for weight in weights {
            for binding in resolved {
                guard let entity = binding.entity else {
                    throw Chapter03AngelBlendShapeError.entityReleased(
                        binding.entityPath
                    )
                }
                var groups = entity.blendWeights
                guard groups.indices.contains(binding.groupIndex),
                      groups[binding.groupIndex].indices.contains(binding.weightIndex) else {
                    throw Chapter03AngelBlendShapeError.staleBinding
                }
                groups[binding.groupIndex][binding.weightIndex] = weight
                entity.blendWeights = groups
            }
        }
        return Report(
            modelEntityCount: Set(resolved.map(\.entityPath)).count,
            bindings: resolved.map {
                Binding(
                    entityPath: $0.entityPath,
                    groupIndex: $0.groupIndex,
                    weightIndex: $0.weightIndex,
                    weightName: $0.weightName
                )
            },
            testedWeights: weights,
            returnedToZero: resolved.allSatisfy { binding in
                guard let entity = binding.entity else { return false }
                return entity.blendWeights[binding.groupIndex][binding.weightIndex] == 0
            }
        )
    }
}
#endif
