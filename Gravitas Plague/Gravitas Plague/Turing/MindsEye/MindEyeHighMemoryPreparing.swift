import Foundation

nonisolated enum MindEyeActiveHighMemoryRetentionPolicy:
    String,
    Sendable,
    Equatable
{
    case retainMatchingRunActive
    case releaseAll
}

nonisolated struct MindEyeHighMemoryPreparationReport:
    Sendable,
    Equatable
{
    let runID: String
    let policy: MindEyeActiveHighMemoryRetentionPolicy
    let preparedVisualReleased: Bool
    let preparedAuthoredTrackReleased: Bool
    let activePresentationRetained: Bool
    let activePresentationReleased: Bool
    let retainedActiveRunID: String?
    let assetCacheBefore: Int
    let assetCacheAfter: Int
    let authoredTrackCacheBefore: Int
    let authoredTrackCacheAfter: Int
    let forcedEvictionApplied: Bool
    let visualRegistryEntriesAfter: Int
    let authoredRegistryEntriesAfter: Int
    let generatedRegistryEntriesAfter: Int
}

@MainActor
protocol MindEyeHighMemoryPreparing: AnyObject {
    func prepareForTuringHighMemoryRun(
        runID: String,
        policy: MindEyeActiveHighMemoryRetentionPolicy
    ) async -> MindEyeHighMemoryPreparationReport
}
