#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation
import RealityKit

@MainActor
enum AngelBlendShapePoseCapture {
    static let orderedGeometryPoses: [(MindEyeMouthPose, Float)] = [
        (.rest, 0),
        (.small, 0.33),
        (.round, 0.5),
        (.wide, 1),
    ]

    static func assign(
        _ weight: Float,
        bindings: [Chapter03AngelBlendShapeBinding]
    ) throws {
        guard (0 ... 1).contains(weight) else {
            throw Chapter03AngelBlendShapeError.invalidDescriptor(
                "captureWeight"
            )
        }
        for binding in bindings {
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
}
#endif
