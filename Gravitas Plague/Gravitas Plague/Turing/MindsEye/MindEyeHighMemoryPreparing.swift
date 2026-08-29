import Foundation

nonisolated enum MindEyeActiveHighMemoryRetentionPolicy:
    String,
    Sendable,
    Equatable
{
    /// Retain only when the active visual already belongs to the compute run.
    case retainMatchingRunActive
    /// Retain the audible authored portrait while a child TTS response run starts.
    case retainActivePresentation
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
        policy: MindEyeActiveHighMemoryRetentionPolicy,
        continuity: TuringSpokenPresentationContinuity?
    ) async -> MindEyeHighMemoryPreparationReport
}

extension MindEyeHighMemoryPreparing {
    func prepareForTuringHighMemoryRun(
        runID: String,
        policy: MindEyeActiveHighMemoryRetentionPolicy
    ) async -> MindEyeHighMemoryPreparationReport {
        await prepareForTuringHighMemoryRun(
            runID: runID,
            policy: policy,
            continuity: nil
        )
    }
}
