import Foundation

extension Notification.Name {
    nonisolated static let chapter02ProgressDidChange = Notification.Name(
        "chapter02ProgressDidChange"
    )
}

nonisolated enum Chapter02Checkpoint: String, Codable, Sendable, Comparable {
    case root = "chapter02.root"
    case missingPersonsCompleted = "chapter02.missingPersons.completed"
    case dadHamCompleted = "chapter02.dadHam.completed"
    case bigMikeWalkieCompleted = "chapter02.bigMikeWalkie.completed"
    case dadPhotoCompleted = "chapter02.dadPhoto.completed"
    case blackoutBroadcastCompleted = "chapter02.blackoutBroadcast.completed"
    case womanExitPending = "chapter02.womanExit.pending"
    case womanBattlePending = "chapter02.womanBattle.pending"
    case womanBattleCompleted = "chapter02.womanBattle.completed"
    case postBattleHamCompleted = "chapter02.postBattleHam.completed"
    case gravitasPSACompleted = "chapter02.gravitasPSA.completed"
    case complete = "chapter02.complete"

    private var rank: Int {
        switch self {
        case .root: return 0
        case .missingPersonsCompleted: return 1
        case .dadHamCompleted: return 2
        case .bigMikeWalkieCompleted: return 3
        case .dadPhotoCompleted: return 4
        case .blackoutBroadcastCompleted: return 5
        case .womanExitPending: return 6
        case .womanBattlePending: return 7
        case .womanBattleCompleted: return 8
        case .postBattleHamCompleted: return 9
        case .gravitasPSACompleted: return 10
        case .complete: return 11
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct Chapter02ProgressSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var checkpoint: Chapter02Checkpoint
    var revision: Int
    var sourceEventIDs: Set<UUID>
    var committedAt: Date
    var contentRevision: String
}

actor Chapter02ProgressStore {
    static let shared = Chapter02ProgressStore()

    nonisolated enum Key {
        static let snapshot = "story.chapter02.progress.v1"
    }

    nonisolated static let contentRevision = "chapter02.v1"

    private let defaults: UserDefaults
    private var snapshot: Chapter02ProgressSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Key.snapshot),
              let value = try? Self.decode(data) else {
            return
        }
        snapshot = value
    }

    nonisolated static func decode(
        _ data: Data
    ) throws -> Chapter02ProgressSnapshot {
        let value = try JSONDecoder().decode(
            Chapter02ProgressSnapshot.self,
            from: data
        )
        guard value.schemaVersion == Chapter02ProgressSnapshot.currentSchemaVersion,
              value.contentRevision == contentRevision else {
            throw TuringRuntimeError.invalidConfig(
                "Chapter 02 progress is incompatible with this build."
            )
        }
        return value
    }

    func currentSnapshot() -> Chapter02ProgressSnapshot? {
        snapshot
    }

    @discardableResult
    func resetForReplay(
        sourceEventID: UUID
    ) throws -> Chapter02ProgressSnapshot {
        let next = Chapter02ProgressSnapshot(
            schemaVersion: Chapter02ProgressSnapshot.currentSchemaVersion,
            checkpoint: .root,
            revision: (snapshot?.revision ?? 0) + 1,
            sourceEventIDs: [sourceEventID],
            committedAt: Date(),
            contentRevision: Self.contentRevision
        )
        try persist(next)
        return next
    }

    @discardableResult
    func commit(
        _ checkpoint: Chapter02Checkpoint,
        sourceEventID: UUID
    ) throws -> Chapter02ProgressSnapshot {
        if let snapshot, snapshot.sourceEventIDs.contains(sourceEventID) {
            return snapshot
        }
        if let snapshot, checkpoint < snapshot.checkpoint {
            return snapshot
        }
        var next = snapshot ?? Chapter02ProgressSnapshot(
            schemaVersion: Chapter02ProgressSnapshot.currentSchemaVersion,
            checkpoint: .root,
            revision: 0,
            sourceEventIDs: [],
            committedAt: Date(),
            contentRevision: Self.contentRevision
        )
        next.checkpoint = checkpoint
        next.revision += 1
        next.sourceEventIDs.insert(sourceEventID)
        next.committedAt = Date()
        try persist(next)
        return next
    }

    func clear(reason: String) {
        defaults.removeObject(forKey: Key.snapshot)
        snapshot = nil
        NotificationCenter.default.post(
            name: .chapter02ProgressDidChange,
            object: nil
        )
        print("[Chapter02Progress] cleared reason=\(reason)")
    }

    private func persist(_ value: Chapter02ProgressSnapshot) throws {
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: Key.snapshot)
        snapshot = value
        NotificationCenter.default.post(
            name: .chapter02ProgressDidChange,
            object: nil
        )
        print(
            "[Chapter02Progress] committed checkpoint=\(value.checkpoint.rawValue) revision=\(value.revision)"
        )
    }
}
