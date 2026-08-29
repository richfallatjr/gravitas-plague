import Foundation

nonisolated struct MindEyeGeneratedFramePlaybackRegistration: Sendable, Equatable {
    let token: UUID
    let initialUpdate: MindEyeGeneratedMouthUpdate?
}

nonisolated enum MindEyeGeneratedFrameAdvanceResult: Sendable, Equatable {
    case unchanged
    case delivered
    case missing
    case failed
}

@MainActor
final class MindEyeGeneratedFramePlaybackRegistry {
    static let shared = MindEyeGeneratedFramePlaybackRegistry()

    private final class WeakSink {
        weak var value: (any MindEyeGeneratedMouthPlaybackSink)?
        init(_ value: any MindEyeGeneratedMouthPlaybackSink) { self.value = value }
    }

    private struct Entry {
        let sink: WeakSink
        var session: MindEyeGeneratedFramePlaybackSession
        var audioPaused: Bool
        var presentationSuspended: Bool

        var shouldAdvance: Bool {
            !audioPaused && !presentationSuspended
        }
    }

    private var entries: [UUID: Entry] = [:]
    private init() {}

    func register(
        sink: any MindEyeGeneratedMouthPlaybackSink,
        context: MindEyeGeneratedMouthPlaybackContext,
        counts: MindEyeMouthVariantCounts,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> Result<MindEyeGeneratedFramePlaybackRegistration, MindEyeFailure> {
        let plan: MindEyeGeneratedMouthVariantPlan
        switch MindEyeGeneratedMouthVariantPlanBuilder.build(
            track: context.track, counts: counts, rootSeed: context.resolvedRootSeed
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): plan = value
        }
        var session = MindEyeGeneratedFramePlaybackSession(
            presentationKey: context.presentationKey,
            segmentIndex: context.segmentIndex,
            track: context.track,
            variantPlan: plan,
            clock: context.clock
        )
        let initial: MindEyeGeneratedMouthUpdate?
        switch session.sample(at: now) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): initial = value
        }
        let token = UUID()
        entries[token] = Entry(
            sink: WeakSink(sink),
            session: session,
            audioPaused: context.clock.isPaused,
            presentationSuspended: false
        )
        return .success(.init(token: token, initialUpdate: initial))
    }

    func advance(
        token: UUID,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> MindEyeGeneratedFrameAdvanceResult {
        guard var entry = entries[token] else { return .missing }
        guard entry.shouldAdvance else { return .unchanged }
        guard let sink = entry.sink.value else { entries.removeValue(forKey: token); return .missing }
        let result = entry.session.sample(at: now)
        entries[token] = entry
        switch result {
        case .failure(let failure):
            entries.removeValue(forKey: token)
            sink.receiveMindEyeGeneratedMouthFailure(failure)
            return .failed
        case .success(nil): return .unchanged
        case .success(let update?):
            sink.receiveMindEyeGeneratedMouthUpdate(update)
            return .delivered
        }
    }

    func updateClock(
        token: UUID,
        clock: TuringPauseAwarePlaybackClock,
        isPaused: Bool,
        sampleAt instant: ContinuousClock.Instant? = nil
    ) -> MindEyeGeneratedFrameAdvanceResult {
        guard var entry = entries[token] else { return .missing }
        entry.session.replaceClock(clock)
        entry.audioPaused = isPaused
        entries[token] = entry
        if let instant, entry.shouldAdvance { return advance(token: token, now: instant) }
        return .unchanged
    }

    func setPresentationSuspended(
        token: UUID,
        suspended: Bool,
        resampleAt instant: ContinuousClock.Instant?
    ) -> MindEyeGeneratedFrameAdvanceResult {
        guard var entry = entries[token] else { return .missing }
        entry.presentationSuspended = suspended
        entries[token] = entry
        if let instant, entry.shouldAdvance { return advance(token: token, now: instant) }
        return .unchanged
    }

    func unregister(token: UUID, reason: String) {
        entries.removeValue(forKey: token)
        print("[MindEyeGenerated] playback unregistered token=\(token.uuidString) reason=\(reason)")
    }

    func removeAll(reason: String) {
        entries.removeAll(keepingCapacity: false)
        print("[MindEyeGenerated] registry cleared reason=\(reason)")
    }

    var entryCount: Int { entries.count }
}
