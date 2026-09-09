import Foundation

nonisolated enum CharacterVocalRole: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case presenceLoop = "presence_loop"
    case damageHit = "damage_hits"
    case death = "death"
}

nonisolated struct CharacterVocalPlaybackIdentity: Sendable, Equatable, Hashable {
    let playbackID: UUID
    let sourceID: UUID
    let characterID: String
    let archetype: PlagueCharacterArchetype
    let role: CharacterVocalRole
    let fileName: String
    let isLooping: Bool
}

nonisolated struct CharacterVocalPlaybackStart: Sendable, Equatable {
    let identity: CharacterVocalPlaybackIdentity
    let clockOrigin: ContinuousClock.Instant
    let expectedDurationSeconds: Double?
}

nonisolated enum CharacterVocalPlaybackEvent: Sendable, Equatable {
    case started(CharacterVocalPlaybackStart)
    case completed(CharacterVocalPlaybackIdentity)
    case cancelled(CharacterVocalPlaybackIdentity, reason: String)
    case sourceRemoved(sourceID: UUID, reason: String)

    var sourceID: UUID {
        switch self {
        case .started(let start):
            start.identity.sourceID
        case .completed(let identity), .cancelled(let identity, _):
            identity.sourceID
        case .sourceRemoved(let sourceID, _):
            sourceID
        }
    }
}

@MainActor
final class CharacterVocalPlaybackEventHub {
    typealias Sink = @MainActor (CharacterVocalPlaybackEvent) -> Void

    @MainActor
    final class Subscription {
        private weak var hub: CharacterVocalPlaybackEventHub?
        private let id: UUID

        fileprivate init(hub: CharacterVocalPlaybackEventHub, id: UUID) {
            self.hub = hub
            self.id = id
        }

        func cancel() {
            hub?.remove(id)
            hub = nil
        }

        deinit {
            let hub = hub
            let id = id
            Task { @MainActor in
                hub?.remove(id)
            }
        }
    }

    private var sinks: [UUID: Sink] = [:]

    func subscribe(_ sink: @escaping Sink) -> Subscription {
        let id = UUID()
        sinks[id] = sink
        return Subscription(hub: self, id: id)
    }

    func publish(_ event: CharacterVocalPlaybackEvent) {
        for sink in Array(sinks.values) {
            sink(event)
        }
    }

    private func remove(_ id: UUID) {
        sinks.removeValue(forKey: id)
    }
}
