import Foundation

nonisolated protocol TuringSpokenPresentationEventPublishing: Sendable {
    func emit(_ event: TuringSpokenPresentationEvent) async
}

actor TuringSpokenPresentationHub:
    TuringSpokenPresentationEventPublishing
{
    static let shared = TuringSpokenPresentationHub()

    private var continuations:
        [UUID: AsyncStream<TuringSpokenPresentationEvent>.Continuation] = [:]

    func events() -> AsyncStream<TuringSpokenPresentationEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func emit(_ event: TuringSpokenPresentationEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
