import Foundation

nonisolated enum MindEyeGeneratedFramePosition: Sendable, Equatable {
    case frame(Int)
    case pastEnd
}

nonisolated enum MindEyeGeneratedFrameClockMapper {
    private static let attosecondsPerNanosecond: Int64 = 1_000_000_000
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    static func position(
        clock: TuringPauseAwarePlaybackClock,
        at instant: ContinuousClock.Instant,
        track: MindEyeGeneratedFrameTrack
    ) -> Result<MindEyeGeneratedFramePosition, MindEyeFailure> {
        position(elapsed: clock.elapsed(at: instant), track: track)
    }

    static func position(
        elapsed: Duration,
        track: MindEyeGeneratedFrameTrack
    ) -> Result<MindEyeGeneratedFramePosition, MindEyeFailure> {
        guard track.sampleRate > 0, track.sampleCount > 0, track.frameCount > 0 else {
            return .failure(failure("Generated frame timeline contract is invalid."))
        }
        let components = elapsed.components
        guard components.seconds >= 0 else { return .success(.frame(0)) }
        let nanoseconds = max(0, components.attoseconds) / attosecondsPerNanosecond
        let whole = components.seconds.multipliedReportingOverflow(by: Int64(track.sampleRate))
        guard !whole.overflow else { return .success(.pastEnd) }
        let fraction = nanoseconds.multipliedReportingOverflow(by: Int64(track.sampleRate))
        guard !fraction.overflow else { return .success(.pastEnd) }
        let sample = whole.partialValue.addingReportingOverflow(
            fraction.partialValue / nanosecondsPerSecond
        )
        guard !sample.overflow else { return .success(.pastEnd) }
        guard sample.partialValue < Int64(track.sampleCount) else { return .success(.pastEnd) }
        let numerator = sample.partialValue.multipliedReportingOverflow(by: 60)
        guard !numerator.overflow else { return .success(.pastEnd) }
        let frameIndex = Int(numerator.partialValue / Int64(track.sampleRate))
        guard frameIndex >= 0, frameIndex < track.frameCount else {
            return .failure(failure("Generated frame clock mapped outside the validated track."))
        }
        return .success(.frame(frameIndex))
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .generatedFrameClockInvalid,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
