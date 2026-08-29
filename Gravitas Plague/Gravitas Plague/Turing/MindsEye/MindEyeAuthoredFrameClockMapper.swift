import Foundation

nonisolated enum MindEyeAuthoredFramePosition: Sendable, Equatable {
    case frame(index: Int)
    case pastEnd
}

nonisolated enum MindEyeAuthoredFrameClockMapper {
    private static let attosecondsPerNanosecond: Int64 = 1_000_000_000
    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    static func position(
        clock: TuringPauseAwarePlaybackClock,
        at instant: ContinuousClock.Instant,
        track: MindEyeAuthoredFrameTrack
    ) -> Result<MindEyeAuthoredFramePosition, MindEyeFailure> {
        position(elapsed: clock.elapsed(at: instant), track: track)
    }

    static func position(
        elapsed: Duration,
        track: MindEyeAuthoredFrameTrack
    ) -> Result<MindEyeAuthoredFramePosition, MindEyeFailure> {
        let descriptor = track.descriptor
        guard descriptor.sampleRate == 48_000,
              descriptor.samplesPerNominalFrame == 800,
              descriptor.framesPerSecond == 60,
              descriptor.sampleCount > 0,
              descriptor.frameCount > 0 else {
            return .failure(failure(descriptor, "Authored frame timeline contract is invalid."))
        }

        let components = elapsed.components
        guard components.seconds >= 0 else { return .success(.frame(index: 0)) }
        let nanoseconds = max(0, components.attoseconds) / attosecondsPerNanosecond
        let whole = components.seconds.multipliedReportingOverflow(
            by: Int64(descriptor.sampleRate)
        )
        guard !whole.overflow else { return .success(.pastEnd) }
        let fraction = nanoseconds.multipliedReportingOverflow(
            by: Int64(descriptor.sampleRate)
        )
        guard !fraction.overflow else { return .success(.pastEnd) }
        let sample = whole.partialValue.addingReportingOverflow(
            fraction.partialValue / nanosecondsPerSecond
        )
        guard !sample.overflow else { return .success(.pastEnd) }
        guard sample.partialValue < Int64(descriptor.sampleCount) else {
            return .success(.pastEnd)
        }
        let frameIndex = Int(
            sample.partialValue / Int64(descriptor.samplesPerNominalFrame)
        )
        guard frameIndex >= 0, frameIndex < descriptor.frameCount else {
            return .failure(failure(
                descriptor,
                "Pause-aware authored frame position is outside the validated timeline."
            ))
        }
        return .success(.frame(index: frameIndex))
    }

    private static func failure(
        _ descriptor: MindEyeAuthoredFrameTrackDescriptor,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredFrameClockInvalid,
            characterID: descriptor.speakerCharacterID,
            vignetteID: nil,
            resourcePath: descriptor.manifestResourcePath,
            message: message
        )
    }
}
