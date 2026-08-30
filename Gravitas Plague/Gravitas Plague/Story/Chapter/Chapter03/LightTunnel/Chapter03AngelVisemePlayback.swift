import Foundation

@MainActor
final class Chapter03AngelVisemePlayback {
    nonisolated struct Sample: Sendable, Equatable {
        let elapsedSeconds: Double
        let frame: Int
        let pose: MindEyeMouthPose
        let multiplier: Float
        let reachedTrackEnd: Bool
    }

    let runID: UUID
    let playbackID: UUID
    private let track: Chapter03AngelVisemeTrack
    private let clockOrigin: ContinuousClock.Instant
    private var cursor = 0
    private(set) var lastPose: MindEyeMouthPose = .rest

    init(
        runID: UUID,
        playbackID: UUID,
        track: Chapter03AngelVisemeTrack,
        clockOrigin: ContinuousClock.Instant
    ) {
        self.runID = runID
        self.playbackID = playbackID
        self.track = track
        self.clockOrigin = clockOrigin
    }

    func sample(now: ContinuousClock.Instant = .now) -> Sample {
        let components = clockOrigin.duration(to: now).components
        let elapsed = max(
            0,
            Double(components.seconds) + Double(components.attoseconds) / 1.0e18
        )
        let frame = Int(floor(elapsed * Double(track.framesPerSecond)))
        guard frame < track.frameCount else {
            lastPose = .rest
            return Sample(
                elapsedSeconds: elapsed,
                frame: frame,
                pose: .rest,
                multiplier: 1,
                reachedTrackEnd: true
            )
        }
        let pose = track.pose(atFrame: frame, cursor: &cursor)
        lastPose = pose
        return Sample(
            elapsedSeconds: elapsed,
            frame: frame,
            pose: pose,
            multiplier: PortalFXVisemeDensityMapper.multiplier(for: pose),
            reachedTrackEnd: false
        )
    }
}
