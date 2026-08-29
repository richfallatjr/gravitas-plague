import Foundation

nonisolated enum TuringGeneratedSpeechAnalysisEvent: Sendable {
    case queued(identity: TuringGeneratedSpeechAnalysisIdentity)
    case started(identity: TuringGeneratedSpeechAnalysisIdentity, queueDelayNanoseconds: UInt64)
    case ready(
        identity: TuringGeneratedSpeechAnalysisIdentity,
        analysis: TuringGeneratedSpeechVisualAnalysis,
        timing: TuringGeneratedSpeechAnalysisTiming
    )
    case unavailable(
        identity: TuringGeneratedSpeechAnalysisIdentity,
        reason: TuringGeneratedSpeechAnalysisUnavailableReason,
        timing: TuringGeneratedSpeechAnalysisTiming
    )
    case cancelled(identity: TuringGeneratedSpeechAnalysisIdentity, reason: String)
}

actor TuringGeneratedSpeechAnalysisEventHub {
    static let shared = TuringGeneratedSpeechAnalysisEventHub()
    private var continuations: [UUID: AsyncStream<TuringGeneratedSpeechAnalysisEvent>.Continuation] = [:]

    func events() -> AsyncStream<TuringGeneratedSpeechAnalysisEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func publish(_ event: TuringGeneratedSpeechAnalysisEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
}
