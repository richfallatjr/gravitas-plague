import Foundation

nonisolated struct MindEyeRuntimeSnapshot:
    Sendable,
    Equatable
{
    let applicationState: MindEyeApplicationLifecycleState
    let memoryPressure: MindEyeMemoryPressureLevel
    let physicalSuppressionActive: Bool
    let lifecycleGeneration: UInt64
    let allowsNewPresentation: Bool
    let activePresentation: MindEyePresentationIdentity?
    let desiredMediaIdentity: String?
    let preparedVignetteID: String?
    let preparedAuthoredPRID: String?
    let motionRegistryEntries: Int
    let authoredRegistryEntries: Int
    let generatedRegistryEntries: Int
    let assetMemorySnapshot: MindEyeAssetMemorySnapshot
    let authoredStoreSnapshot: MindEyeAuthoredFrameStoreSnapshot
}
