import Foundation

nonisolated struct TuringStoryDoorBattleOpeningBeganEvent:
    Sendable,
    Equatable
{
    enum Origin: String, Sendable {
        case playerAcceptedOpen
        case coordinatorAutoOpen
        case reconciledAlreadyOpening
        case reconciledAlreadyOpen
    }

    let eventID: UUID
    let battleInstanceID: UUID
    let origin: Origin
    let reason: String
    let doorStateAtEmission: TuringStoryDoorBattleState
}

@MainActor
final class TuringStoryDoorBattleOpeningObservation {
    private var cancelBody: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelBody = cancel
    }

    func cancel() {
        cancelBody?()
        cancelBody = nil
    }

    deinit {
        cancelBody?()
    }
}
