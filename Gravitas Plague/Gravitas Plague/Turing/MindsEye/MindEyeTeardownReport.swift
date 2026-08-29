import Foundation

nonisolated enum MindEyeTeardownScope:
    String,
    Sendable,
    Equatable
{
    case spokenItem
    case response
    case physicalSuppression
    case storyBoundary
    case chapterReset
    case storyTeleport
    case operationMode
    case applicationBackground
    case memoryCritical
    case immersiveShutdown
}

nonisolated struct MindEyeTeardownReport:
    Sendable,
    Equatable
{
    let scope: MindEyeTeardownScope
    let reason: String
    let lifecycleGeneration: UInt64
    let activeVisualRemoved: Bool
    let preparedVisualRemoved: Bool
    let activeAuthoredTrackReleased: Bool
    let preparedAuthoredTrackReleased: Bool
    let motionRegistryEntries: Int
    let authoredRegistryEntries: Int
    let generatedRegistryEntries: Int
    let cachedAssetPackages: Int
    let cachedAuthoredTracks: Int
    let providerCount: Int
    let desiredContextPresent: Bool
    let preparationTaskPresent: Bool
    let authoredTrackTaskPresent: Bool
}
