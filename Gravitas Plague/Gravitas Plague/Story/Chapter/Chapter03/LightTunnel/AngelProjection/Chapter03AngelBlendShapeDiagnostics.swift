import Foundation

@MainActor
enum Chapter03AngelBlendShapeDiagnostics {
    static func loaded(
        descriptor: Chapter03AngelBlendShapeDescriptor,
        bindings: [Chapter03AngelBlendShapeBinding]
    ) {
        let targets = bindings.map {
            "\($0.entityPath)[\($0.groupIndex)][\($0.weightIndex)]"
        }.joined(separator: ",")
        print(
            "[Chapter03AngelBlendShape] loaded " +
                "assetSHA=\(descriptor.assetSHA256) " +
                "target=\(descriptor.blendShapeName) " +
                "bindings=\(bindings.count) targets=\(targets) " +
                "mapping=rest:0,teeth:0,small:0.33,round:0.5,wide:1"
        )
    }

    static func fallbackToBase(error: Error) {
        print(
            "[Chapter03AngelBlendShape] base fallback active " +
                "error=\(String(describing: error))"
        )
    }

    static func poseChanged(_ pose: MindEyeMouthPose, target: Float) {
        print(
            "[Chapter03AngelBlendShape] pose=\(pose.rawValue) target=\(target)"
        )
    }

    static func readinessChanged(_ readiness: Chapter03AngelProjectionReadiness) {
        print(
            "[Chapter03AngelBlendShape] projectionReady=\(readiness.isReady) " +
                "camera=\(readiness.cameraReady) material=\(readiness.materialReady) " +
                "texture=\(readiness.textureReady) mask=\(readiness.maskReady) " +
                "blendShape=\(readiness.blendShapeReady)"
        )
    }

    static func assignmentFailed(error: Error) {
        print(
            "[Chapter03AngelBlendShape] assignment failed; closing to base " +
                "error=\(String(describing: error))"
        )
    }

    static func reset(reason: String, assignmentCount: UInt64) {
        print(
            "[Chapter03AngelBlendShape] reset reason=\(reason) " +
                "assignmentCount=\(assignmentCount)"
        )
    }
}
