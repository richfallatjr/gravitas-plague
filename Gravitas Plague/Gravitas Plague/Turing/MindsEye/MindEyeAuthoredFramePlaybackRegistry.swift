import Foundation

nonisolated struct MindEyeAuthoredFramePlaybackRegistration:
    Sendable,
    Equatable
{
    let token: UUID
    let initialUpdate: MindEyeAuthoredMouthUpdate?
}

nonisolated enum MindEyeAuthoredFrameAdvanceResult: Sendable, Equatable {
    case unchanged
    case delivered
    case missing
    case failed
}

@MainActor
final class MindEyeAuthoredFramePlaybackRegistry {
    static let shared = MindEyeAuthoredFramePlaybackRegistry()

    private final class WeakSink {
        weak var value: (any MindEyeAuthoredMouthPlaybackSink)?
        init(_ value: any MindEyeAuthoredMouthPlaybackSink) { self.value = value }
    }

    private struct Entry {
        let sink: WeakSink
        var session: MindEyeAuthoredFramePlaybackSession
        var audioPaused: Bool
        var presentationSuspended: Bool

        var shouldAdvance: Bool {
            !audioPaused && !presentationSuspended
        }
    }

    private var entries: [UUID: Entry] = [:]
    private init() {}

    func register(
        sink: any MindEyeAuthoredMouthPlaybackSink,
        context: MindEyeAuthoredMouthPlaybackContext,
        counts: MindEyeMouthVariantCounts,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> Result<MindEyeAuthoredFramePlaybackRegistration, MindEyeFailure> {
        let plan: MindEyeAuthoredMouthVariantPlan
        switch MindEyeAuthoredMouthVariantPlanBuilder.build(
            track: context.track,
            counts: counts,
            rootSeed: context.resolvedRootSeed
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): plan = value
        }
        var session = MindEyeAuthoredFramePlaybackSession(
            presentationKey: context.presentationKey,
            track: context.track,
            clock: context.clock,
            variantPlan: plan
        )
        let initial: MindEyeAuthoredMouthUpdate?
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
    ) -> MindEyeAuthoredFrameAdvanceResult {
        guard var entry = entries[token] else { return .missing }
        guard entry.shouldAdvance else { return .unchanged }
        guard let sink = entry.sink.value else {
            entries.removeValue(forKey: token)
            return .missing
        }
        let result = entry.session.sample(at: now)
        entries[token] = entry
        switch result {
        case .failure(let failure):
            entries.removeValue(forKey: token)
            sink.receiveMindEyeAuthoredMouthFailure(failure)
            return .failed
        case .success(nil): return .unchanged
        case .success(let update?):
            sink.receiveMindEyeAuthoredMouthUpdate(update)
            return .delivered
        }
    }

    func updateClock(
        token: UUID,
        clock: TuringPauseAwarePlaybackClock,
        isPaused: Bool,
        sampleAt instant: ContinuousClock.Instant? = nil
    ) -> MindEyeAuthoredFrameAdvanceResult {
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
    ) -> MindEyeAuthoredFrameAdvanceResult {
        guard var entry = entries[token] else { return .missing }
        entry.presentationSuspended = suspended
        entries[token] = entry
        if let instant, entry.shouldAdvance { return advance(token: token, now: instant) }
        return .unchanged
    }

    func unregister(token: UUID, reason: String) {
        entries.removeValue(forKey: token)
        print("[MindEyeAuthored] playback unregistered token=\(token.uuidString) reason=\(reason)")
    }

    func removeAll(reason: String) {
        entries.removeAll(keepingCapacity: false)
        print("[MindEyeAuthored] registry cleared reason=\(reason)")
    }

    var entryCount: Int { entries.count }
}
