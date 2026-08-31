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
            try binding.setWeight(weight)
        }
    }
}
#endif
