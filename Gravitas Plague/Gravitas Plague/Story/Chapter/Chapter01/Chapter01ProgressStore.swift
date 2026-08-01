import Foundation

enum Chapter01Checkpoint: String, Codable, Sendable, Comparable {
    case root = "chapter01.root"
    case script06Completed = "chapter01.script06.completed"
    case script07Completed = "chapter01.script07.completed"
    case dadWindowPending = "chapter01.dadWindow.pending"
    case robotEncounterPending = "chapter01.robotEncounter.pending"
    case antigenGranted = "chapter01.antigenGranted"
    case hamScript04Pending = "chapter01.hamScript04.pending"

    private var rank: Int {
        switch self {
        case .root: return 0
        case .script06Completed: return 1
        case .script07Completed: return 2
        case .dadWindowPending: return 3
        case .robotEncounterPending: return 4
        case .antigenGranted: return 5
        case .hamScript04Pending: return 6
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var supportedContinuationCheckpoint: Chapter01Checkpoint? {
        switch self {
        case .root, .script06Completed:
            return nil
        case .script07Completed,
             .dadWindowPending,
             .robotEncounterPending,
             .antigenGranted,
             .hamScript04Pending:
            return .dadWindowPending
        }
    }
}

struct Chapter01ProgressSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let checkpoint: Chapter01Checkpoint
    let revision: Int
    let sourceEventID: UUID
    let committedAt: Date
    let contentRevision: String
}

actor Chapter01ProgressStore {
    static let shared = Chapter01ProgressStore()

    enum Key {
        static let snapshot = "story.chapter01.progress.v1"
    }

    static let contentRevision = "chapter01.v1"

    private let defaults: UserDefaults
    private var snapshot: Chapter01ProgressSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.snapshot),
           let value = try? JSONDecoder().decode(Chapter01ProgressSnapshot.self, from: data),
           value.schemaVersion == Chapter01ProgressSnapshot.currentSchemaVersion,
           value.contentRevision == Self.contentRevision {
            snapshot = value
        }
    }

    @discardableResult
    func commit(
        _ checkpoint: Chapter01Checkpoint,
        sourceEventID: UUID
    ) throws -> Chapter01ProgressSnapshot {
        if let snapshot, snapshot.sourceEventID == sourceEventID {
            return snapshot
        }
        if let snapshot, checkpoint < snapshot.checkpoint {
            return snapshot
        }
        let next = Chapter01ProgressSnapshot(
            schemaVersion: Chapter01ProgressSnapshot.currentSchemaVersion,
            checkpoint: checkpoint,
            revision: (snapshot?.revision ?? 0) + 1,
            sourceEventID: sourceEventID,
            committedAt: Date(),
            contentRevision: Self.contentRevision
        )
        defaults.set(
            try JSONEncoder().encode(next),
            forKey: Key.snapshot
        )
        snapshot = next
        print("[Chapter01Progress] committed checkpoint=\(checkpoint.rawValue) revision=\(next.revision)")
        return next
    }

    func currentSnapshot() -> Chapter01ProgressSnapshot? { snapshot }

    func clear(reason: String) {
        defaults.removeObject(forKey: Key.snapshot)
        snapshot = nil
        print("[Chapter01Progress] cleared reason=\(reason)")
    }

    @discardableResult
    func resetForReplay(
        sourceEventID: UUID
    ) throws -> Chapter01ProgressSnapshot {
        clear(reason: "chapter01Replay")
        return try commit(.root, sourceEventID: sourceEventID)
    }
}
