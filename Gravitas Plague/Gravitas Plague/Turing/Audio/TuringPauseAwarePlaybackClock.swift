import Foundation

/// A public-API monotonic approximation of audible media time.
///
/// The origin is captured by the actual playback backend immediately after
/// start. Pause and resume instants must come from the same ContinuousClock.
/// Completion remains authoritative from the audio backend.
nonisolated struct TuringPauseAwarePlaybackClock:
    Sendable,
    Equatable
{
    let origin: ContinuousClock.Instant
    private(set) var accumulatedPausedDuration: Duration
    private(set) var pausedAt: ContinuousClock.Instant?

    init(origin: ContinuousClock.Instant) {
        self.origin = origin
        accumulatedPausedDuration = .zero
        pausedAt = nil
    }

    var isPaused: Bool {
        pausedAt != nil
    }

    mutating func pause(at instant: ContinuousClock.Instant) {
        guard pausedAt == nil else { return }
        pausedAt = instant < origin ? origin : instant
    }

    mutating func resume(at instant: ContinuousClock.Instant) {
        guard let pausedAt else { return }
        let duration = pausedAt.duration(to: instant)
        if duration > .zero {
            accumulatedPausedDuration += duration
        }
        self.pausedAt = nil
    }

    func elapsed(at instant: ContinuousClock.Instant) -> Duration {
        let endpoint = pausedAt ?? instant
        let raw = origin.duration(to: endpoint) - accumulatedPausedDuration
        return raw > .zero ? raw : .zero
    }
}
