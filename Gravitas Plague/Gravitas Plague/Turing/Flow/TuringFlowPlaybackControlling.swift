import Foundation

nonisolated protocol TuringFlowPlaybackControlling: AnyObject, Sendable {
    func configureFlowIdentity(_ identity: TuringFlowIdentity) async

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async

    func beginAuthoredRun(identity: TuringFlowIdentity) async
    func configureGeneratedPlayback(
        _ configuration: TuringGeneratedPlaybackConfiguration
    ) async
    func generatedPlaybackGateDidChange() async
    func enqueueAuthoredMedia(_ item: TuringAuthoredMediaItem) async throws
    func sealAuthoredInput() async
    func waitUntilAuthoredPlaybackFinished() async throws
    func setPlaybackLifecycleSink(
        _ sink: (any TuringFlowPlaybackLifecycleSink)?
    ) async
    func lifecycleEvents() async -> AsyncStream<TuringFlowPlaybackLifecycleEvent>
    func acquireAuthoredProgressionHold(
        liveSessionID: UUID,
        reason: String
    ) async throws -> TuringAuthoredProgressionHoldToken
    func releaseAuthoredProgressionHold(
        _ token: TuringAuthoredProgressionHoldToken,
        reason: String
    ) async throws
    func waitUntilCurrentSpokenItemCompletes(
        hold: TuringAuthoredProgressionHoldToken
    ) async throws

    func expectPrerecordingBeforeGenerated() async

    func enqueuePrerecording(id: String, fileURL: URL) async
    func enqueueAuthoredBridge(
        id: String,
        fileURL: URL,
        beforeGeneratedSegmentIndex: Int
    ) async
    func setExpectedGeneratedSegmentCount(_ count: Int) async
    func qwenComputeStarted(segmentIndex: Int) async
    func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async
    func qwenComputeSkipped(segmentIndex: Int, reason: String) async
    func qwenComputeAllFinished() async
    func sealGeneratedInput(finalExpectedSegmentCount: Int) async
    func qwenComputeFailed(
        expectedSegmentCount: Int,
        reason: String
    ) async
    func waitUntilPlaybackFinished() async
    func completedGeneratedSegmentCount() async -> Int
    func runCancelled(reason: String) async
}

extension TuringFlowPlaybackControlling {
    func setPlaybackLifecycleSink(
        _ sink: (any TuringFlowPlaybackLifecycleSink)?
    ) async {}

    func configureGeneratedPlayback(
        _ configuration: TuringGeneratedPlaybackConfiguration
    ) async {}

    func generatedPlaybackGateDidChange() async {}

    func lifecycleEvents() async -> AsyncStream<TuringFlowPlaybackLifecycleEvent> {
        AsyncStream { $0.finish() }
    }

    func acquireAuthoredProgressionHold(
        liveSessionID: UUID,
        reason: String
    ) async throws -> TuringAuthoredProgressionHoldToken {
        throw TuringRuntimeError.invalidConfig(
            "Playback owner does not support authored progression holds."
        )
    }

    func releaseAuthoredProgressionHold(
        _ token: TuringAuthoredProgressionHoldToken,
        reason: String
    ) async throws {}

    func waitUntilCurrentSpokenItemCompletes(
        hold: TuringAuthoredProgressionHoldToken
    ) async throws {}
}
