import Foundation

@MainActor
protocol MindEyeAuthoredMouthControlling: AnyObject {
    func startAuthoredMouthPlayback(
        context: MindEyeAuthoredMouthPlaybackContext
    ) -> Result<Void, MindEyeFailure>
    func updateAuthoredMouthClock(
        _ clock: TuringPauseAwarePlaybackClock,
        paused: Bool,
        instant: ContinuousClock.Instant?,
        reason: String
    )
    func stopAuthoredMouthPlayback(reason: String, resetToRest: Bool)
}

nonisolated struct MindEyeAuthoredPlaybackSnapshot: Sendable, Equatable {
    let isInstalled: Bool
    let isPaused: Bool
    let prID: String?
    let manifestSHA256: String?
    let trackFrameIndex: Int?
    let poseRunIndex: Int?
    let pose: MindEyeMouthPose?
    let variantIndex: Int?
    let isPastEnd: Bool
    let compactFrameBytes: Int
    let poseRunCount: Int
}
