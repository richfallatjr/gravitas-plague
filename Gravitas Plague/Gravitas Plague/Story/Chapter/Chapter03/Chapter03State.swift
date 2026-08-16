import Foundation

nonisolated enum Chapter03Checkpoint: String, Codable, Sendable, Comparable {
    case root = "chapter03.root"
    case lightTunnelPending = "chapter03.lightTunnel.pending"
    case endCardPending = "chapter03.endCard.pending"
    case complete = "chapter03.complete"

    private var rank: Int {
        switch self {
        case .root: return 0
        case .lightTunnelPending: return 1
        case .endCardPending: return 2
        case .complete: return 3
        }
    }

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct Chapter03ProgressSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let currentContentRevision = "chapter03.lightTunnelTest.v2"

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
    case preparingTunnel(UUID)
    case portalApproaching(UUID)
    case portalArrived(UUID)
    case drainingAuthoredMedia(UUID)
    case ending(UUID)
    case complete
    case failed(UUID, String)
    case cancelled
}
