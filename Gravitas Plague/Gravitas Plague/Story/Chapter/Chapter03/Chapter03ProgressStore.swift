import Foundation

extension Notification.Name {
    nonisolated static let chapter03ProgressDidChange = Notification.Name(
        "chapter03ProgressDidChange"
    )
}

actor Chapter03ProgressStore {
    static let shared = Chapter03ProgressStore()

    nonisolated enum Key {
        static let snapshot = "story.chapter03.progress.v1"
    }

    private let defaults: UserDefaults
    private var snapshot: Chapter03ProgressSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Key.snapshot) else {
            return
        }
        do {
            let decoded = try Self.decodeOrMigrate(data)
            snapshot = decoded
            if decoded.contentRevision == Chapter03ProgressSnapshot.currentContentRevision {
                defaults.set(try JSONEncoder().encode(decoded), forKey: Key.snapshot)
            }
        } catch {
            print("[Chapter03Progress] incompatible snapshot retained for diagnosis error=\(error.localizedDescription)")
        }
    }

    nonisolated static func decode(
        _ data: Data
    ) throws -> Chapter03ProgressSnapshot {
        try decodeOrMigrate(data)
    }

    nonisolated static func decodeOrMigrate(
        _ data: Data,
        now: Date = Date()
    ) throws -> Chapter03ProgressSnapshot {
        let value = try JSONDecoder().decode(
            Chapter03ProgressSnapshot.self,
            from: data
        )
        guard value.schemaVersion == Chapter03ProgressSnapshot.currentSchemaVersion else {
            throw Chapter03Error.incompatibleProgress
        }
        if value.contentRevision == Chapter03ProgressSnapshot.currentContentRevision {
            return value
        }
        guard value.contentRevision == "chapter03.lightTunnelTest.v2" else {
            throw Chapter03Error.incompatibleProgress
        }
        // The legacy revision represented a tunnel-only development route. It
        // cannot prove completion of the production battles and device flows.
        return Chapter03ProgressSnapshot(
            schemaVersion: Chapter03ProgressSnapshot.currentSchemaVersion,
            contentRevision: Chapter03ProgressSnapshot.currentContentRevision,
            checkpoint: .root,
            revision: value.revision + 1,
            sourceEventIDs: value.sourceEventIDs,
            committedAt: now
        )
    }

    func currentSnapshot() -> Chapter03ProgressSnapshot? {
        snapshot
    }

    @discardableResult
    func resetForReplay(sourceEventID: UUID) throws -> Chapter03ProgressSnapshot {
        let next = Chapter03ProgressSnapshot(
            schemaVersion: Chapter03ProgressSnapshot.currentSchemaVersion,
            contentRevision: Chapter03ProgressSnapshot.currentContentRevision,
            checkpoint: .root,
            revision: (snapshot?.revision ?? 0) + 1,
            sourceEventIDs: [sourceEventID],
            committedAt: Date()
        )
        try persist(next)
        return next
    }

    @discardableResult
    func commit(
        _ checkpoint: Chapter03Checkpoint,
        sourceEventID: UUID
    ) throws -> Chapter03ProgressSnapshot {
        if let snapshot, snapshot.sourceEventIDs.contains(sourceEventID) {
            return snapshot
        }
        if let snapshot, checkpoint < snapshot.checkpoint {
            return snapshot
        }
        var next = snapshot ?? Chapter03ProgressSnapshot(
            schemaVersion: Chapter03ProgressSnapshot.currentSchemaVersion,
            contentRevision: Chapter03ProgressSnapshot.currentContentRevision,
            checkpoint: .root,
            revision: 0,
            sourceEventIDs: [],
            committedAt: Date()
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
            name: .chapter03ProgressDidChange,
            object: nil
        )
        print("[Chapter03Progress] cleared reason=\(reason)")
    }

    private func persist(_ value: Chapter03ProgressSnapshot) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: Key.snapshot)
        snapshot = value
        NotificationCenter.default.post(
            name: .chapter03ProgressDidChange,
            object: nil
        )
        print(
            "[Chapter03Progress] committed checkpoint=\(value.checkpoint.rawValue) " +
                "revision=\(value.revision)"
        )
    }
}
