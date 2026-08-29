import Foundation

nonisolated enum TuringFlowPlaybackLifecycleEvent: Sendable, Equatable {
    case authoredMediaStarted(
        runID: String,
        item: TuringAuthoredMediaItem,
        handle: TuringAudioPlaybackHandle
    )
    case authoredMediaPaused(
        runID: String,
        itemID: String,
        handle: TuringAudioPlaybackHandle,
        interruptionID: UUID
    )
    case authoredMediaResumed(
        runID: String,
        itemID: String,
        handle: TuringAudioPlaybackHandle,
        interruptionID: UUID
    )
    case authoredMediaCompleted(
        runID: String,
        itemID: String,
        handle: TuringAudioPlaybackHandle
    )
    case generatedSegmentStarted(
        runID: String,
        segmentIndex: Int,
        handle: TuringAudioPlaybackHandle
    )
    case generatedSegmentCompleted(
        runID: String,
        segmentIndex: Int,
        handle: TuringAudioPlaybackHandle
    )
    case generatedPlaybackCompleted(
        runID: String,
        finalSegmentIndex: Int
    )
    case failed(runID: String, reason: String)

    var runID: String {
        switch self {
        case .authoredMediaStarted(let runID, _, _),
             .authoredMediaPaused(let runID, _, _, _),
             .authoredMediaResumed(let runID, _, _, _),
             .authoredMediaCompleted(let runID, _, _),
             .generatedSegmentStarted(let runID, _, _),
             .generatedSegmentCompleted(let runID, _, _),
             .generatedPlaybackCompleted(let runID, _),
             .failed(let runID, _):
            return runID
        }
    }
}

@MainActor
protocol TuringFlowPlaybackLifecycleSink: AnyObject, Sendable {
    func receivePlaybackLifecycleEvent(
        _ event: TuringFlowPlaybackLifecycleEvent
    ) async
}

nonisolated struct TuringAuthoredProgressionHoldToken:
    Sendable,
    Equatable,
    Hashable
{
    let id: UUID
    let playbackRunID: String
    let liveSessionID: UUID
}

nonisolated struct TuringSpokenCoverPauseReceipt: Sendable, Equatable {
    enum Result: Sendable, Equatable {
        case paused
        case completedBeforePause
    }

    let interruptionID: UUID
    let playbackRunID: String
    let itemIdentity: String
    let handle: TuringAudioPlaybackHandle?
    let result: Result
}

nonisolated protocol TuringSpokenCoverControlling: AnyObject, Sendable {
    func pauseCurrentSpokenMedia(
        interruptionID: UUID
    ) async throws -> TuringSpokenCoverPauseReceipt

    func resumeCurrentSpokenMedia(
        _ receipt: TuringSpokenCoverPauseReceipt
    ) async throws

    func waitUntilSpokenMediaCompletes(
        _ receipt: TuringSpokenCoverPauseReceipt
    ) async throws
}

actor TuringFlowPlaybackLifecycleHub {
    private var continuations:
        [UUID: AsyncStream<TuringFlowPlaybackLifecycleEvent>.Continuation] = [:]

    func stream() -> AsyncStream<TuringFlowPlaybackLifecycleEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func yield(_ event: TuringFlowPlaybackLifecycleEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
