import Foundation

nonisolated struct TuringGeneratedSpeechAnalysisIdentity: Sendable, Equatable, Hashable {
    let ticketID: UUID
    let runID: String
    let segmentIndex: Int
}

nonisolated struct TuringGeneratedSpeechAnalysisTiming: Sendable, Equatable {
    let queuedAt: ContinuousClock.Instant
    let startedAt: ContinuousClock.Instant?
    let completedAt: ContinuousClock.Instant?
    let queueDelayNanoseconds: UInt64?
    let computeNanoseconds: UInt64?
    let totalLatencyNanoseconds: UInt64?
}

nonisolated final class TuringGeneratedSpeechAnalysisResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TuringGeneratedSpeechAnalysisResult?

    func store(_ result: TuringGeneratedSpeechAnalysisResult) {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return }
        stored = result
    }

    func resultIfReady() -> TuringGeneratedSpeechAnalysisResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

nonisolated struct TuringGeneratedSpeechAnalysisTicket: Sendable, Equatable, Hashable {
    let identity: TuringGeneratedSpeechAnalysisIdentity
    let resultBox: TuringGeneratedSpeechAnalysisResultBox

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

nonisolated final class TuringGeneratedSpeechAnalysisCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
