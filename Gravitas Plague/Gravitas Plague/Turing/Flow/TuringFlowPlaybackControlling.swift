import Foundation

nonisolated protocol TuringFlowPlaybackControlling: AnyObject, Sendable {
    func configureFlowIdentity(_ identity: TuringFlowIdentity) async

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async

    func beginAuthoredRun(identity: TuringFlowIdentity) async
    func enqueueAuthoredMedia(_ item: TuringAuthoredMediaItem) async throws
    func sealAuthoredInput() async
    func waitUntilAuthoredPlaybackFinished() async throws

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
