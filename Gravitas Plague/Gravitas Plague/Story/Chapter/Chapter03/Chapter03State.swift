import Foundation

nonisolated enum Chapter03Checkpoint: String, Codable, Sendable, Comparable {
    case root = "chapter03.root"
    case bikerBattlePending = "chapter03.bikerBattle.pending"
    case bikerBattleCompleted = "chapter03.bikerBattle.completed"
    case walkieCompleted = "chapter03.walkie.completed"
    case hamCompleted = "chapter03.ham.completed"
    case continuityBroadcastCompleted = "chapter03.continuityBroadcast.completed"
    case mikeBattlePending = "chapter03.mikeBattle.pending"
    case heavenTransitionPending = "chapter03.heavenTransition.pending"
    case lightTunnelPending = "chapter03.lightTunnel.pending"
    case endCardPending = "chapter03.endCard.pending"
    case complete = "chapter03.complete"

    private var rank: Int {
        switch self {
        case .root: return 0
        case .bikerBattlePending: return 1
        case .bikerBattleCompleted: return 2
        case .walkieCompleted: return 3
        case .hamCompleted: return 4
        case .continuityBroadcastCompleted: return 5
        case .mikeBattlePending: return 6
        case .heavenTransitionPending: return 7
        case .lightTunnelPending: return 8
        case .endCardPending: return 9
        case .complete: return 10
        }
    }

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct Chapter03ProgressSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let currentContentRevision = "chapter03.v1"

    let schemaVersion: Int
    let contentRevision: String
    var checkpoint: Chapter03Checkpoint
    var revision: UInt64
    var sourceEventIDs: Set<UUID>
    var committedAt: Date
}

enum Chapter03State: Sendable, Equatable {
    case idle
    case acceptingRoot(UUID)
    case preparingBiker(UUID)
    case bikerBattle(UUID)
    case walkieReady(UUID)
    case hamReady(UUID)
    case continuityBroadcastReady(UUID)
    case preparingMike(UUID)
    case mikeBattle(UUID)
    case mikeSurrender(UUID)
    case suppressingRoom(UUID)
    case preparingTunnel(UUID)
    case portalApproaching(UUID)
    case portalArrived(UUID)
    case drainingAuthoredMedia(UUID)
    case ending(UUID)
    case complete
    case failed(UUID, String)
    case cancelled
}
