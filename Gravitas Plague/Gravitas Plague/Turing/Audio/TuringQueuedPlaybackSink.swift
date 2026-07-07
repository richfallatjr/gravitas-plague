import Foundation

struct TuringPlaybackHandle: Sendable {
    let id: UUID
    let label: String
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        label: String,
        duration: TimeInterval
    ) {
        self.id = id
        self.label = label
        self.duration = duration
    }
}

@MainActor
protocol TuringQueuedPlaybackSink: AnyObject {
    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async

    func playGeneratedSegment(
        _ audio: TuringComputeGapGeneratedAudio
    ) async throws -> TuringPlaybackHandle

    func playGeneratedWAVSegment(
        _ wav: TuringGeneratedWAVSegment
    ) async throws -> TuringPlaybackHandle

    func playFillerClip(
        fileURL: URL,
        label: String
    ) async throws -> TuringPlaybackHandle

    func waitForPlaybackCompletion(
        _ handle: TuringPlaybackHandle
    ) async

    func startStaticLoop(
        fileURL: URL,
        reason: String
    ) async throws

    func stopStaticLoop(reason: String) async

    func cancelRun(reason: String) async
}
