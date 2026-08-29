import Foundation

nonisolated enum MindEyeDurationNanoseconds {
    static func clampedUInt64(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        let fractional = components.attoseconds > 0
            ? UInt64(components.attoseconds / 1_000_000_000)
            : 0
        let (result, additionOverflow) = whole.addingReportingOverflow(fractional)
        return additionOverflow ? UInt64.max : result
    }
}

actor MindEyeReleaseQualificationRecorder {
    static let shared = MindEyeReleaseQualificationRecorder()

    private var activeRun: MindEyeReleaseScenarioRun?
    private var runOrigin: ContinuousClock.Instant?
    private var events: [MindEyeReleaseQualificationEvent] = []
    private var nextOrdinal: UInt64 = 0

    func begin(run: MindEyeReleaseScenarioRun) throws {
        guard activeRun == nil else {
            throw MindEyeReleaseQualificationError.runAlreadyActive
        }
        guard run.sequenceNumber >= 0 else {
            throw MindEyeReleaseQualificationError.invalidRun
        }
        activeRun = run
        runOrigin = .now
        events.removeAll(keepingCapacity: true)
        nextOrdinal = 0
    }

    func record(
        checkpoint: MindEyeQualificationCheckpoint,
        playbackRunID: String?,
        mediaIdentity: String?,
        speakerCharacterID: String?,
        interactionSurface: String?,
        resource: MindEyeReleaseResourceSnapshot,
        timing: MindEyeReleaseTimingSnapshot,
        notes: [String]
    ) throws {
        guard let activeRun, let runOrigin else {
            throw MindEyeReleaseQualificationError.noActiveRun
        }
        let elapsed = MindEyeDurationNanoseconds.clampedUInt64(
            runOrigin.duration(to: .now)
        )
        events.append(MindEyeReleaseQualificationEvent(
            schemaVersion: 1,
            run: activeRun,
            ordinal: nextOrdinal,
            checkpoint: checkpoint,
            continuousNanosecondsSinceRunStart: elapsed,
            playbackRunID: playbackRunID,
            mediaIdentity: mediaIdentity,
            speakerCharacterID: speakerCharacterID,
            interactionSurface: interactionSurface,
            resource: resource,
            timing: timing,
            notes: notes.sorted()
        ))
        nextOrdinal &+= 1
    }

    func finish() throws -> MindEyeReleaseQualificationReport {
        guard let run = activeRun else {
            throw MindEyeReleaseQualificationError.noActiveRun
        }
        let report = MindEyeReleaseQualificationReport(
            schemaVersion: 1,
            reportVersion: "mind-eye-release-qualification/1",
            run: run,
            events: events,
            generatedAtUTC: nil
        )
        activeRun = nil
        runOrigin = nil
        events = []
        nextOrdinal = 0
        return report
    }

    func cancel() {
        activeRun = nil
        runOrigin = nil
        events = []
        nextOrdinal = 0
    }
}
