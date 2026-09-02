import Combine
import Foundation

enum TuringStoryContinuationTarget: Sendable, Equatable {
    case prologue(TuringEpisodeContinuationSnapshot)
    case chapter01(Chapter01ProgressSnapshot)
    case chapter02(Chapter02ProgressSnapshot)
    case chapter03(Chapter03ProgressSnapshot)

    var episodeID: TuringEpisodeID {
        switch self {
        case .prologue:
            return .prologue
        case .chapter01:
            return .chapter01
        case .chapter02:
            return .chapter02
        case .chapter03:
            return .chapter03
        }
    }

    var committedAt: Date {
        switch self {
        case .prologue(let snapshot):
            return snapshot.committedAt
        case .chapter01(let snapshot):
            return snapshot.committedAt
        case .chapter02(let snapshot):
            return snapshot.committedAt
        case .chapter03(let snapshot):
            return snapshot.committedAt
        }
    }

    var checkpointDescription: String {
        switch self {
        case .prologue(let snapshot):
            return String(describing: snapshot.checkpoint)
        case .chapter01(let snapshot):
            return snapshot.checkpoint.supportedContinuationCheckpoint?
                .rawValue ?? snapshot.checkpoint.rawValue
        case .chapter02(let snapshot):
            return snapshot.checkpoint.rawValue
        case .chapter03(let snapshot):
            return snapshot.checkpoint.rawValue
        }
    }

    var titleCardDescriptor: StoryTitleCardDescriptor {
        switch self {
        case .prologue, .chapter01, .chapter02, .chapter03:
            return StoryTitleCardCatalog.descriptor(for: episodeID)
        }
    }

    var titleCardDestination: StoryTitleCardDestination {
        switch self {
        case .prologue, .chapter01, .chapter02, .chapter03:
            return .continueFrom(self)
        }
    }
}

@MainActor
final class TuringStoryProgressStore: ObservableObject {
    static let shared = TuringStoryProgressStore()

    enum Key {
        static let snapshot = "turing.story.continuation.snapshot.v1"
    }

    static let prologueContentRevision = "prologue.v1"

    @Published private(set) var snapshot: TuringEpisodeContinuationSnapshot?
    @Published private(set) var chapter01Snapshot: Chapter01ProgressSnapshot?
    @Published private(set) var chapter02Snapshot: Chapter02ProgressSnapshot?
    @Published private(set) var chapter03Snapshot: Chapter03ProgressSnapshot?
    @Published private(set) var invalidSnapshotReason: String?
    @Published private(set) var invalidChapter01SnapshotReason: String?
    @Published private(set) var invalidChapter02SnapshotReason: String?
    @Published private(set) var invalidChapter03SnapshotReason: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reloadFromDefaults()
        NotificationCenter.default.publisher(
            for: .chapter01ProgressDidChange
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.reloadChapter01FromDefaults()
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: .chapter03ProgressDidChange
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.reloadChapter03FromDefaults()
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: .chapter02ProgressDidChange
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.reloadChapter02FromDefaults()
        }
        .store(in: &cancellables)
    }

    var canContinue: Bool {
        continuationTarget != nil
    }

    var continuationTarget: TuringStoryContinuationTarget? {
        let prologueTarget: TuringStoryContinuationTarget? = {
            guard let snapshot,
                  isCompatible(snapshot),
                  snapshot.checkpoint != .notStarted else {
                return nil
            }
            return .prologue(snapshot)
        }()
        let chapterTarget: TuringStoryContinuationTarget? = {
            guard let chapter01Snapshot,
                  chapter01Snapshot.contentRevision ==
                    Chapter01ProgressStore.contentRevision,
                  chapter01Snapshot.checkpoint
                    .supportedContinuationCheckpoint != nil else {
                return nil
            }
            return .chapter01(chapter01Snapshot)
        }()
        let chapter02Target: TuringStoryContinuationTarget? = {
            guard let chapter02Snapshot,
                  chapter02Snapshot.contentRevision ==
                    Chapter02ProgressStore.contentRevision else {
                return nil
            }
            return .chapter02(chapter02Snapshot)
        }()

        let chapter03Target: TuringStoryContinuationTarget? = {
            guard let chapter03Snapshot,
                  chapter03Snapshot.contentRevision ==
                    Chapter03ProgressSnapshot.currentContentRevision else {
                return nil
            }
            return .chapter03(chapter03Snapshot)
        }()

        return [prologueTarget, chapterTarget, chapter02Target, chapter03Target]
            .compactMap { $0 }
            .max(by: { $0.committedAt < $1.committedAt })
    }

    var accessibilitySummary: String {
        guard let target = continuationTarget else {
            return "No valid Story progress is available."
        }
        return "Resume \(target.episodeID.rawValue) from \(target.checkpointDescription)."
    }

    func reloadFromDefaults() {
        invalidSnapshotReason = nil
        invalidChapter01SnapshotReason = nil
        invalidChapter02SnapshotReason = nil
        invalidChapter03SnapshotReason = nil
        reloadPrologueFromDefaults()
        reloadChapter01FromDefaults()
        reloadChapter02FromDefaults()
        reloadChapter03FromDefaults()
    }

    private func reloadPrologueFromDefaults() {
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

    private func reloadChapter01FromDefaults() {
        guard let data = defaults.data(
            forKey: Chapter01ProgressStore.Key.snapshot
        ) else {
            chapter01Snapshot = nil
            return
        }

        do {
            let value = try Chapter01ProgressStore.decodeAndMigrate(data)
            guard value.contentRevision ==
                    Chapter01ProgressStore.contentRevision else {
                invalidateChapter01(
                    "Chapter 01 content revision does not match this build."
                )
                return
            }
            if let migrated = try? encoder.encode(value), migrated != data {
                defaults.set(
                    migrated,
                    forKey: Chapter01ProgressStore.Key.snapshot
                )
            }
            chapter01Snapshot = value
        } catch {
            invalidateChapter01(error.localizedDescription)
        }
    }

    private func reloadChapter02FromDefaults() {
        guard let data = defaults.data(
            forKey: Chapter02ProgressStore.Key.snapshot
        ) else {
            chapter02Snapshot = nil
            return
        }

        do {
            chapter02Snapshot = try Chapter02ProgressStore.decode(data)
        } catch {
            chapter02Snapshot = nil
            invalidChapter02SnapshotReason = error.localizedDescription
            print(
                "[TuringContinuation] invalid Chapter02 snapshot reason=\(error.localizedDescription)"
            )
        }
    }

    private func reloadChapter03FromDefaults() {
        guard let data = defaults.data(
            forKey: Chapter03ProgressStore.Key.snapshot
        ) else {
            chapter03Snapshot = nil
            return
        }
        do {
            chapter03Snapshot = try Chapter03ProgressStore.decode(data)
        } catch {
            chapter03Snapshot = nil
            invalidChapter03SnapshotReason = error.localizedDescription
            print(
                "[TuringContinuation] invalid Chapter03 snapshot " +
                    "reason=\(error.localizedDescription)"
            )
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
        guard let snapshot,
              isCompatible(snapshot),
              snapshot.checkpoint != .notStarted else {
            throw TuringStoryContinuationError.noValidSnapshot
        }
        return snapshot
    }

    func requireValidContinuationTarget() throws
        -> TuringStoryContinuationTarget {
        guard let continuationTarget else {
            throw TuringStoryContinuationError.noValidSnapshot
        }
        return continuationTarget
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

    private func invalidateChapter01(_ reason: String) {
        chapter01Snapshot = nil
        invalidChapter01SnapshotReason = reason
        print(
            "[TuringContinuation] invalid Chapter01 snapshot reason=\(reason)"
        )
    }
}
