import Foundation

@MainActor
public protocol TuringSpeechPlaybackSink: AnyObject {
    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async

    func playGeneratedSegment(
        _ audio: TuringComputeGapGeneratedAudio
    ) async throws -> TimeInterval

    func waitForGeneratedSegmentPlaybackCompletion(
        segmentIndex: Int,
        fallbackDuration: TimeInterval
    ) async

    func playFillerClip(
        fileURL: URL,
        label: String
    ) async throws -> TimeInterval

    func stopAll(reason: String) async
}
