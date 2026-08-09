import Foundation

nonisolated enum StoryHeavyRuntimeKind: Hashable, Sendable {
    case dad(UUID)
    case chapter02Woman(UUID)
    case robot(BattleEnemyRuntimeIdentity)
    case portalMirror(chapterRunID: UUID, mirrorID: UUID)

    var chapterRunID: UUID {
        switch self {
        case .dad(let id):
            return id
        case .chapter02Woman(let id):
            return id
        case .robot(let identity):
            return identity.battleInstanceID
        case .portalMirror(let chapterRunID, _):
            return chapterRunID
        }
    }
}

actor StoryHeavyRuntimeRegistry {
    static let shared = StoryHeavyRuntimeRegistry()

    private var active = Set<StoryHeavyRuntimeKind>()

    func register(_ runtime: StoryHeavyRuntimeKind) {
        active.insert(runtime)
        print("[StoryHeavyRuntime] registered kind=\(runtime)")
    }

    func remove(_ runtime: StoryHeavyRuntimeKind) {
        active.remove(runtime)
        print("[StoryHeavyRuntime] removed kind=\(runtime)")
    }

    func removeAll(matching chapterRunID: UUID) {
        active = active.filter { $0.chapterRunID != chapterRunID }
    }

    func removeRobotOwnedRuntimes(chapterRunID: UUID) {
        active = active.filter { runtime in
            guard runtime.chapterRunID == chapterRunID else { return true }
            if case .dad = runtime { return true }
            if case .chapter02Woman = runtime { return true }
            return false
        }
    }

    func snapshot(chapterRunID: UUID) -> [StoryHeavyRuntimeKind] {
        active.filter { $0.chapterRunID == chapterRunID }
    }

    func count(chapterRunID: UUID) -> Int {
        active.reduce(0) { $0 + ($1.chapterRunID == chapterRunID ? 1 : 0) }
    }
}
