import Foundation

nonisolated enum MindEyePhysicalPresenceSuppressionScope:
    String,
    Sendable,
    Equatable,
    Hashable
{
    case matchingCharacter
    case allPresentations
}

nonisolated struct MindEyePhysicalCharacterPresenceLease:
    Sendable,
    Equatable,
    Hashable
{
    let id: UUID
    let characterID: TuringConversationCharacterID
    let scope: MindEyePhysicalPresenceSuppressionScope
    let sourceID: String
    let generation: UInt64
}

nonisolated struct MindEyePhysicalCharacterPresenceClaim:
    Sendable,
    Equatable,
    Hashable
{
    let lease: MindEyePhysicalCharacterPresenceLease
    let reason: String
}

nonisolated struct MindEyePhysicalCharacterPresenceSnapshot:
    Sendable,
    Equatable
{
    let generation: UInt64
    let claims: [MindEyePhysicalCharacterPresenceClaim]

    var suppressesAllPresentations: Bool {
        claims.contains { $0.lease.scope == .allPresentations }
    }

    func suppresses(characterID: TuringConversationCharacterID) -> Bool {
        claims.contains {
            $0.lease.scope == .allPresentations ||
                ($0.lease.scope == .matchingCharacter && $0.lease.characterID == characterID)
        }
    }
}

actor MindEyePhysicalCharacterPresenceHub {
    static let shared = MindEyePhysicalCharacterPresenceHub()

    private var claims: [UUID: MindEyePhysicalCharacterPresenceClaim] = [:]
    private var continuations: [
        UUID: AsyncStream<MindEyePhysicalCharacterPresenceSnapshot>.Continuation
    ] = [:]
    private var generation: UInt64 = 0

    func acquire(
        characterID: TuringConversationCharacterID,
        scope: MindEyePhysicalPresenceSuppressionScope,
        sourceID: String,
        reason: String
    ) throws -> MindEyePhysicalCharacterPresenceLease {
        guard !sourceID.isEmpty,
              !sourceID.contains(".."),
              !sourceID.hasPrefix("/") else {
            throw MindEyeFailure(
                code: .physicalPresenceClaimInvalid,
                characterID: characterID,
                vignetteID: nil,
                resourcePath: nil,
                message: "Physical-character presence source ID is invalid."
            )
        }
        generation &+= 1
        let lease = MindEyePhysicalCharacterPresenceLease(
            id: UUID(),
            characterID: characterID,
            scope: scope,
            sourceID: sourceID,
            generation: generation
        )
        claims[lease.id] = .init(lease: lease, reason: reason)
        publishSnapshot()
        return lease
    }

    func release(_ lease: MindEyePhysicalCharacterPresenceLease, reason: String) {
        guard let stored = claims[lease.id], stored.lease == lease else {
            print(
                "[MindEyePhysicalPresence] stale release ignored " +
                    "source=\(lease.sourceID) reason=\(reason)"
            )
            return
        }
        claims.removeValue(forKey: lease.id)
        generation &+= 1
        publishSnapshot()
    }

    func stream() -> AsyncStream<MindEyePhysicalCharacterPresenceSnapshot> {
        let id = UUID()
        let initial = snapshot()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func currentSnapshot() -> MindEyePhysicalCharacterPresenceSnapshot {
        snapshot()
    }

    func forceRelease(sourcePrefix: String, reason: String) {
        let ids = claims.values
            .filter { $0.lease.sourceID.hasPrefix(sourcePrefix) }
            .map(\.lease.id)
        guard !ids.isEmpty else { return }
        for id in ids { claims.removeValue(forKey: id) }
        generation &+= 1
        publishSnapshot()
        print(
            "[MindEyePhysicalPresence] forced release prefix=\(sourcePrefix) " +
                "count=\(ids.count) reason=\(reason)"
        )
    }

    private func snapshot() -> MindEyePhysicalCharacterPresenceSnapshot {
        .init(
            generation: generation,
            claims: claims.values.sorted {
                let lhs = $0.lease
                let rhs = $1.lease
                if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
                if lhs.characterID.rawValue != rhs.characterID.rawValue {
                    return lhs.characterID.rawValue < rhs.characterID.rawValue
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        )
    }

    private func publishSnapshot() {
        let value = snapshot()
        for continuation in continuations.values { continuation.yield(value) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
