import Foundation

actor TuringConversationPlaybackStartGate {
    enum State: Sendable, Equatable {
        case closed
        case open
        case cancelled(String)
    }

    private var state: State = .closed

    func currentState() -> State { state }

    func open() {
        guard state == .closed else { return }
        state = .open
    }

    func cancel(reason: String) {
        state = .cancelled(reason)
    }
}

nonisolated struct TuringGeneratedPlaybackConfiguration: Sendable {
    enum InitialGapOwnership: Sendable {
        case routeDefault
        case externallyOwned
    }

    let startGate: TuringConversationPlaybackStartGate?
    let initialGapOwnership: InitialGapOwnership

    static let routeDefault = TuringGeneratedPlaybackConfiguration(
        startGate: nil,
        initialGapOwnership: .routeDefault
    )
}
