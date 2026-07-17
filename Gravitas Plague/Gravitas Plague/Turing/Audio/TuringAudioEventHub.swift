import Foundation

actor TuringAudioEventHub {
    private var continuations: [
        UUID: AsyncStream<TuringAudioPlaybackEvent>.Continuation
    ] = [:]

    func stream() -> AsyncStream<TuringAudioPlaybackEvent> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            continuations[subscriberID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(subscriberID) }
            }
        }
    }

    func yield(_ event: TuringAudioPlaybackEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    private func remove(_ subscriberID: UUID) {
        continuations.removeValue(forKey: subscriberID)
    }
}
