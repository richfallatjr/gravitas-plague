import Foundation

actor StoryInteractionSnapshotHub {
    private var continuations: [
        UUID: AsyncStream<StoryInteractionSnapshot>.Continuation
    ] = [:]

    func stream(
        initial: StoryInteractionSnapshot
    ) -> AsyncStream<StoryInteractionSnapshot> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            continuations[subscriberID] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.remove(subscriberID)
                }
            }
        }
    }

    func yield(_ snapshot: StoryInteractionSnapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func remove(_ subscriberID: UUID) {
        continuations.removeValue(forKey: subscriberID)
    }
}
