import Foundation

@MainActor
final class StoryPlayerHitBudget {
    struct Snapshot: Sendable, Equatable {
        let confirmedHits: Int
        let maximum: Int
        let terminal: Bool
    }

    private let maximumConfirmedHits: Int
    private var confirmedHits = 0
    private var terminal = false

    init(maximumConfirmedHits: Int) {
        precondition(maximumConfirmedHits > 0)
        self.maximumConfirmedHits = maximumConfirmedHits
    }

    func registerConfirmedHit() -> Bool {
        guard !terminal else { return true }
        confirmedHits += 1
        terminal = confirmedHits >= maximumConfirmedHits
        return terminal
    }

    func disable() {
        terminal = true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            confirmedHits: confirmedHits,
            maximum: maximumConfirmedHits,
            terminal: terminal
        )
    }
}
