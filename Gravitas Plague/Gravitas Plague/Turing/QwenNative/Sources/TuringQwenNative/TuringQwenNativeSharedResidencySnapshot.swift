import Foundation

public final class TuringQwenNativeSharedResidencySnapshot: @unchecked Sendable {
    public let identity: TuringQwenNativeResidencyIdentity
    let modelResources: TuringQwenNativeResidentResources
    let cloneConditioning: TuringQwenNativeSharedCloneConditioning

    init(
        identity: TuringQwenNativeResidencyIdentity,
        modelResources: TuringQwenNativeResidentResources,
        cloneConditioning: TuringQwenNativeSharedCloneConditioning
    ) {
        self.identity = identity
        self.modelResources = modelResources
        self.cloneConditioning = cloneConditioning
    }
}
