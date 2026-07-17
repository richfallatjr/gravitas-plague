import Combine
import Foundation

@MainActor
final class TuringStoryProgressStore: ObservableObject {
    static let shared = TuringStoryProgressStore()

    enum Key {
        static let snapshot = "turing.story.continuation.snapshot.v1"
    }

    static let prologueContentRevision = "prologue.v1"

    @Published private(set) var snapshot: TuringEpisodeContinuationSnapshot?
    @Published private(set) var invalidSnapshotReason: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reloadFromDefaults()
    }

    var canContinue: Bool {
        guard let snapshot else { return false }
        return isCompatible(snapshot) && snapshot.checkpoint != .notStarted
    }

    var accessibilitySummary: String {
        guard let snapshot, canContinue else {
            return "No valid Story progress is available."
        }
        return "Resume \(snapshot.episodeID.rawValue) from \(snapshot.checkpoint)."
    }

    func reloadFromDefaults() {
        invalidSnapshotReason = nil
        guard let encoded = defaults.string(forKey: Key.snapshot) else {
            snapshot = nil
            return
        }
        guard let data = Data(base64Encoded: encoded) else {
            invalidate("Saved Story progress is not valid base64.")
            return
        }

        do {
            let value = try decoder.decode(
                TuringEpisodeContinuationSnapshot.self,
                from: data
            )
            guard value.schemaVersion == TuringEpisodeContinuationSnapshot.currentSchemaVersion else {
                invalidate("Unsupported Story save schema \(value.schemaVersion).")
                return
            }
            guard isCompatible(value) else {
                invalidate("Story content revision does not match this build.")
                return
            }
            let supportedValue = supportedSnapshot(from: value)
            if supportedValue != value {
                try persist(supportedValue)
                print("[TuringContinuation] later checkpoint migrated to Battle01 start requested=\(value.checkpoint) effective=\(supportedValue.checkpoint)")
            }
            snapshot = supportedValue
        } catch {
            invalidate(error.localizedDescription)
        }
    }

    @discardableResult
    func commit(
        episodeID: TuringEpisodeID,
        checkpoint: TuringPrologueCheckpoint,
        sourceEventID: UUID,
        contentRevision: String
    ) throws -> TuringEpisodeContinuationSnapshot {
        guard contentRevision == Self.prologueContentRevision else {
            throw TuringStoryContinuationError.contentRevisionMismatch
        }
        let supportedCheckpoint = checkpoint.supportedContinuationValue
        if supportedCheckpoint != checkpoint {
            print("[TuringContinuation] later checkpoint capped at Battle01 start requested=\(checkpoint) effective=\(supportedCheckpoint)")
        }
        if let current = snapshot, current.sourceEventID == sourceEventID {
            return current
        }
        if let current = snapshot, current.episodeID == episodeID {
            guard supportedCheckpoint > current.checkpoint else {
                print("[TuringContinuation] non-advancing checkpoint ignored current=\(current.checkpoint) requested=\(supportedCheckpoint)")
                return current
            }
        }

        let next = TuringEpisodeContinuationSnapshot(
            schemaVersion: TuringEpisodeContinuationSnapshot.currentSchemaVersion,
            episodeID: episodeID,
            checkpoint: supportedCheckpoint,
            revision: (snapshot?.revision ?? 0) + 1,
            committedAt: Date(),
            sourceEventID: sourceEventID,
            contentRevision: contentRevision
        )
        try persist(next)
        snapshot = next
        invalidSnapshotReason = nil
        print("""
        [TuringContinuation] checkpoint committed
          episodeID: \(episodeID.rawValue)
          checkpoint: \(supportedCheckpoint)
          revision: \(next.revision)
          sourceEventID: \(sourceEventID.uuidString)
        """)
        return next
    }

    func requireValidSnapshot() throws -> TuringEpisodeContinuationSnapshot {
        guard let snapshot, canContinue else {
            throw TuringStoryContinuationError.noValidSnapshot
        }
        return snapshot
    }

    func clear(reason: String) {
        defaults.removeObject(forKey: Key.snapshot)
        snapshot = nil
        invalidSnapshotReason = nil
        print("[TuringContinuation] cleared reason=\(reason)")
    }

    private func isCompatible(_ value: TuringEpisodeContinuationSnapshot) -> Bool {
        value.episodeID == .prologue &&
            value.contentRevision == Self.prologueContentRevision
    }

    private func supportedSnapshot(
        from value: TuringEpisodeContinuationSnapshot
    ) -> TuringEpisodeContinuationSnapshot {
        let checkpoint = value.checkpoint.supportedContinuationValue
        guard checkpoint != value.checkpoint else { return value }
        return TuringEpisodeContinuationSnapshot(
            schemaVersion: value.schemaVersion,
            episodeID: value.episodeID,
            checkpoint: checkpoint,
            revision: value.revision + 1,
            committedAt: Date(),
            sourceEventID: value.sourceEventID,
            contentRevision: value.contentRevision
        )
    }

    private func persist(_ value: TuringEpisodeContinuationSnapshot) throws {
        let data = try encoder.encode(value)
        defaults.set(data.base64EncodedString(), forKey: Key.snapshot)
    }

    private func invalidate(_ reason: String) {
        snapshot = nil
        invalidSnapshotReason = reason
        print("[TuringContinuation] invalid snapshot reason=\(reason)")
    }
}
