import Foundation

#if GR_MIND_EYE_QUALIFICATION
nonisolated enum MindEyeQualifiedSystem {
    case motion
    case authored
    case generated
}

@MainActor
final class MindEyeReleaseQualificationHooks {
    static let shared = MindEyeReleaseQualificationHooks()

    private var coordinator: MindEyeReleaseQualificationCoordinator?
    private var eventTail: Task<Void, Never>?
    private var spokenEventTask: Task<Void, Never>?
    private var audioOriginsByPlaybackRunID: [String: ContinuousClock.Instant] = [:]
    private var motionSystemMilliseconds: [Double] = []
    private var authoredSystemMilliseconds: [Double] = []
    private var generatedSystemMilliseconds: [Double] = []
    private var compositorEncodeMilliseconds: [Double] = []
    private var compositorGPUMilliseconds: [Double] = []
    private var frameIntervalMilliseconds: [Double] = []
    private let maximumSamplesPerSeries = 8_192

    func install(
        snapshotProvider: @escaping MindEyeReleaseQualificationCoordinator.SnapshotProvider
    ) async {
        coordinator = MindEyeReleaseQualificationCoordinator(
            snapshotProvider: snapshotProvider
        )
        eventTail?.cancel()
        eventTail = nil
        spokenEventTask?.cancel()
        spokenEventTask = nil
        resetMeasurements()
        try? await coordinator?.beginFromLaunchArgumentsIfRequested()
        spokenEventTask = Task { @MainActor [weak self] in
            let stream = await TuringSpokenPresentationHub.shared.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.handleSpokenEvent(event)
            }
        }
        await coordinator?.record(.appCold)
    }

    func fireAndForget(
        _ checkpoint: MindEyeQualificationCheckpoint,
        playbackRunID: String? = nil,
        mediaIdentity: String? = nil,
        speakerCharacterID: String? = nil,
        interactionSurface: String? = nil,
        timing: MindEyeReleaseTimingSnapshot = .empty,
        notes: [String] = []
    ) {
        var observedTiming = timing.fillingMissingValues(from: timingSnapshot())
        if checkpoint == .afterVisualAttach,
           let playbackRunID,
           let origin = audioOriginsByPlaybackRunID[playbackRunID] {
            observedTiming = MindEyeReleaseTimingSnapshot(
                visualReadyAfterActualStartMilliseconds: Self.milliseconds(
                    origin.duration(to: .now)
                )
            ).fillingMissingValues(from: observedTiming)
        }
        let predecessor = eventTail
        let coordinator = coordinator
        let task = Task { @MainActor in
            _ = await predecessor?.value
            guard !Task.isCancelled else { return }
            await coordinator?.record(
                checkpoint,
                playbackRunID: playbackRunID,
                mediaIdentity: mediaIdentity,
                speakerCharacterID: speakerCharacterID,
                interactionSurface: interactionSurface,
                timing: observedTiming,
                notes: notes
            )
        }
        eventTail = task
    }

    func visualReleased() {
        fireAndForget(.visualDismissed)
        fireAndForget(.sourceReferencesReleased)
        let predecessor = eventTail
        let coordinator = coordinator
        Task { @MainActor in
            _ = await predecessor?.value
            guard !Task.isCancelled, let coordinator else { return }
            coordinator.scheduleReleaseObservations()
        }
    }

    func finishAfterShutdown() async {
        _ = await eventTail?.value
        await coordinator?.record(.immersiveShutDown)
        _ = try? await coordinator?.finishAndExport()
        spokenEventTask?.cancel()
        spokenEventTask = nil
        eventTail?.cancel()
        eventTail = nil
        coordinator = nil
        resetMeasurements()
    }

    func recordSystemCPU(
        _ system: MindEyeQualifiedSystem,
        startedAt: ContinuousClock.Instant
    ) {
        let value = Self.milliseconds(startedAt.duration(to: .now))
        switch system {
        case .motion:
            append(value, to: &motionSystemMilliseconds)
        case .authored:
            append(value, to: &authoredSystemMilliseconds)
        case .generated:
            append(value, to: &generatedSystemMilliseconds)
        }
    }

    func recordFrameInterval(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        append(seconds * 1_000, to: &frameIntervalMilliseconds)
    }

    func recordCompositor(_ receipt: MindEyeCompositeFrameReceipt) {
        append(
            Double(receipt.cpuEncodeNanoseconds) / 1_000_000,
            to: &compositorEncodeMilliseconds
        )
        if let nanoseconds = receipt.gpuExecutionNanoseconds {
            append(Double(nanoseconds) / 1_000_000, to: &compositorGPUMilliseconds)
        }
    }

    private func handleSpokenEvent(_ event: TuringSpokenPresentationEvent) {
        switch event {
        case .started(let context):
            audioOriginsByPlaybackRunID[context.run.playbackRunID] = context.clockOrigin
            let checkpoint: MindEyeQualificationCheckpoint
            switch context.source {
            case .authored: checkpoint = .authoredAudioStarted
            case .generated: checkpoint = .generatedAudioStarted
            }
            fireAndForget(
                checkpoint,
                playbackRunID: context.run.playbackRunID,
                mediaIdentity: context.source.mediaIdentity,
                speakerCharacterID: context.speakerCharacterID.rawValue,
                interactionSurface: context.interactionSurface.rawValue,
                timing: MindEyeReleaseTimingSnapshot(
                    actualAudioStartLatencyMilliseconds: Self.milliseconds(
                        context.clockOrigin.duration(to: .now)
                    )
                ),
                notes: ["latency measures audible clock origin to qualification observation"]
            )
        case .authoredItemCompleted(let context, _),
             .generatedSegmentCompleted(let context, _),
             .cancelled(let context, _, _):
            audioOriginsByPlaybackRunID.removeValue(forKey: context.run.playbackRunID)
        case .responseCompleted(let run):
            audioOriginsByPlaybackRunID.removeValue(forKey: run.playbackRunID)
        case .failed(let run, _, _, _):
            audioOriginsByPlaybackRunID.removeValue(forKey: run.playbackRunID)
        case .paused, .resumed:
            break
        }
    }

    private func timingSnapshot() -> MindEyeReleaseTimingSnapshot {
        MindEyeReleaseTimingSnapshot(
            motionSystemCPUP50Milliseconds: Self.percentile(0.50, of: motionSystemMilliseconds),
            motionSystemCPUP95Milliseconds: Self.percentile(0.95, of: motionSystemMilliseconds),
            authoredSystemCPUP50Milliseconds: Self.percentile(0.50, of: authoredSystemMilliseconds),
            authoredSystemCPUP95Milliseconds: Self.percentile(0.95, of: authoredSystemMilliseconds),
            generatedSystemCPUP50Milliseconds: Self.percentile(0.50, of: generatedSystemMilliseconds),
            generatedSystemCPUP95Milliseconds: Self.percentile(0.95, of: generatedSystemMilliseconds),
            compositorEncodeP50Milliseconds: Self.percentile(0.50, of: compositorEncodeMilliseconds),
            compositorEncodeP95Milliseconds: Self.percentile(0.95, of: compositorEncodeMilliseconds),
            compositorGPUP50Milliseconds: Self.percentile(0.50, of: compositorGPUMilliseconds),
            compositorGPUP95Milliseconds: Self.percentile(0.95, of: compositorGPUMilliseconds),
            frameIntervalMilliseconds: Self.percentile(0.50, of: frameIntervalMilliseconds),
            mainThreadFrameP95Milliseconds: Self.percentile(0.95, of: frameIntervalMilliseconds)
        )
    }

    private func append(_ value: Double, to values: inout [Double]) {
        guard value.isFinite, value >= 0 else { return }
        if values.count == maximumSamplesPerSeries {
            values.removeFirst(maximumSamplesPerSeries / 4)
        }
        values.append(value)
    }

    private func resetMeasurements() {
        audioOriginsByPlaybackRunID.removeAll(keepingCapacity: false)
        motionSystemMilliseconds.removeAll(keepingCapacity: false)
        authoredSystemMilliseconds.removeAll(keepingCapacity: false)
        generatedSystemMilliseconds.removeAll(keepingCapacity: false)
        compositorEncodeMilliseconds.removeAll(keepingCapacity: false)
        compositorGPUMilliseconds.removeAll(keepingCapacity: false)
        frameIntervalMilliseconds.removeAll(keepingCapacity: false)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(MindEyeDurationNanoseconds.clampedUInt64(duration)) / 1_000_000
    }

    private static func percentile(_ percentile: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
}
#endif
