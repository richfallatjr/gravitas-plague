import Foundation

public protocol TuringQwenNativeResidencyLoading: Sendable {
    func load(
        token: TuringQwenNativeSharedResidencyOwner.Token,
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String
    ) throws -> TuringQwenNativeSharedResidencySnapshot
}

public struct TuringQwenNativeProductionResidencyLoader:
    TuringQwenNativeResidencyLoading
{
    public init() {}

    public func load(
        token: TuringQwenNativeSharedResidencyOwner.Token,
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String
    ) throws -> TuringQwenNativeSharedResidencySnapshot {
        let recorder = TuringQwenNativeResidencyMetricsRecorder(
            ownerID: token.ownerID
        )
        let context = TuringQwenNativeMLXExecutionContext(
            runID: "sharedResidency.\(token.generation)",
            instanceID: nil,
            phase: .warmLoad,
            stage: "sharedResidency.resources",
            residencyOwnerID: token.ownerID.uuidString
        )
        return try TuringQwenNativeMLXErrorBoundary.run(context: context) {
            try Task.checkCancellation()
            let resources = try TuringQwenNativeResidentResources(
                modelRoot: modelRoot,
                metricsRecorder: recorder
            )
            guard resources.modelID == cloneProfile.modelID else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shared residency model identity does not match the clone profile."
                )
            }
            try Task.checkCancellation()
            let conditioning = try TuringQwenNativeSharedCloneConditioning(
                profile: cloneProfile,
                variantID: variantID
            )
            _ = recorder.record("owner.afterCloneConditioning")
            try Task.checkCancellation()

            let identity = TuringQwenNativeResidencyIdentity(
                ownerID: token.ownerID,
                generation: token.generation,
                modelID: resources.modelID,
                quantization: resources.quantization,
                standardizedModelRootPath: modelRoot.standardizedFileURL.path,
                voiceID: cloneProfile.voiceID,
                variantID: variantID,
                weightStoreID: resources.weightsStore.identity,
                cloneConditioningID: conditioning.identity
            )
            _ = recorder.record("owner.ready")
            return TuringQwenNativeSharedResidencySnapshot(
                identity: identity,
                modelResources: resources,
                cloneConditioning: conditioning
            )
        }
    }
}
