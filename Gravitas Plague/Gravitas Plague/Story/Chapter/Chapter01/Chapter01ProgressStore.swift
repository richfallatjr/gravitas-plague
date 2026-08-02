import Foundation

extension Notification.Name {
    static let chapter01ProgressDidChange = Notification.Name(
        "chapter01ProgressDidChange"
    )
}

enum Chapter01Checkpoint: String, Codable, Sendable, Comparable {
    case root = "chapter01.root"
    case script06Completed = "chapter01.script06.completed"
    case script07Completed = "chapter01.script07.completed"
    case dadWindowPending = "chapter01.dadWindow.pending"
    case robotEncounterPending = "chapter01.robotEncounter.pending"
    case antigenGranted = "chapter01.antigenGranted"
    case hamScript04Pending = "chapter01.hamScript04.pending"
    case postRobotHub = "chapter01.postRobotHub"
    case preDadFinalBattleReady = "chapter01.preDadFinalBattle.ready"

    private var rank: Int {
        switch self {
        case .root: return 0
        case .script06Completed: return 1
        case .script07Completed: return 2
        case .dadWindowPending: return 3
        case .robotEncounterPending: return 4
        case .antigenGranted: return 5
        case .hamScript04Pending: return 6
        case .postRobotHub: return 7
        case .preDadFinalBattleReady: return 8
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var supportedContinuationCheckpoint: Chapter01Checkpoint? {
        switch self {
        case .root, .script06Completed:
            return nil
        case .script07Completed, .dadWindowPending, .robotEncounterPending:
            return .dadWindowPending
        case .antigenGranted, .hamScript04Pending, .postRobotHub:
            return .postRobotHub
        case .preDadFinalBattleReady:
            return .preDadFinalBattleReady
        }
    }
}

enum Chapter01PostRobotBranch: String, Codable, Sendable, CaseIterable {
    case dadFrame
    case walkie
    case hamReceiver

    var terminalScriptPointID: String {
        switch self {
        case .dadFrame:
            return "chapter01.dadFrame.rich.fourChances.001"
        case .walkie:
            return "chapter01.walkie.bigMike.script09"
        case .hamReceiver:
            return "chapter01.hamReceiver.cateye81.script05"
        }
    }
}

struct Chapter01PostRobotProgress: Codable, Sendable, Equatable {
    var unlocked: Bool
    var completedBranches: Set<Chapter01PostRobotBranch>

    static let locked = Chapter01PostRobotProgress(
        unlocked: false,
        completedBranches: []
    )

    var allBranchesComplete: Bool {
        completedBranches == Set(Chapter01PostRobotBranch.allCases)
    }

    func isAvailable(_ branch: Chapter01PostRobotBranch) -> Bool {
        guard unlocked else { return false }
        switch branch {
        case .dadFrame:
            return true
        case .walkie:
            return completedBranches.contains(.dadFrame)
        case .hamReceiver:
            return completedBranches.contains(.walkie)
        }
    }

    func state(
        for branch: Chapter01PostRobotBranch
    ) -> TuringFlowInteractionGateController.State {
        guard isAvailable(branch) else { return .closed }
        return completedBranches.contains(branch) ? .microphone : .play
    }

    func normalizedForSequentialUnlock() -> Self {
        guard unlocked else { return .locked }
        var valid = Set<Chapter01PostRobotBranch>()
        if completedBranches.contains(.dadFrame) {
            valid.insert(.dadFrame)
        }
        if valid.contains(.dadFrame), completedBranches.contains(.walkie) {
            valid.insert(.walkie)
        }
        if valid.contains(.walkie), completedBranches.contains(.hamReceiver) {
            valid.insert(.hamReceiver)
        }
        return Self(unlocked: true, completedBranches: valid)
    }

    var gateStates: [StoryInteractionSurfaceID: TuringFlowInteractionGateController.State] {
        [
            .dadFrame: state(for: .dadFrame),
            .walkie: state(for: .walkie),
            .hamReceiver: state(for: .hamReceiver)
        ]
    }
}

struct Chapter01ProgressSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    var checkpoint: Chapter01Checkpoint
    var postRobot: Chapter01PostRobotProgress
    var revision: Int
    var sourceEventIDs: Set<UUID>
    var committedAt: Date
    var contentRevision: String
}

struct Chapter01PostRobotBranchCompletionResult: Sendable, Equatable {
    let snapshot: Chapter01ProgressSnapshot
    let branch: Chapter01PostRobotBranch
    let wasNewlyCompleted: Bool
    let becameAllBranchesComplete: Bool
}

actor Chapter01ProgressStore {
    static let shared = Chapter01ProgressStore()

    enum Key {
        static let snapshot = "story.chapter01.progress.v1"
    }

    static let contentRevision = "chapter01.v3"

    private struct LegacyV1Snapshot: Codable {
        let schemaVersion: Int
        let checkpoint: Chapter01Checkpoint
        let revision: Int
        let sourceEventID: UUID
        let committedAt: Date
        let contentRevision: String
    }

    private struct LegacyV2Snapshot: Codable {
        let schemaVersion: Int
        var checkpoint: Chapter01Checkpoint
        var postRobot: Chapter01PostRobotProgress
        var revision: Int
        var sourceEventIDs: Set<UUID>
        var committedAt: Date
        var contentRevision: String
    }

    private let defaults: UserDefaults
    private var snapshot: Chapter01ProgressSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Key.snapshot),
              let value = try? Self.decodeAndMigrate(data) else {
            return
        }
        snapshot = value
        if let migrated = try? JSONEncoder().encode(value), migrated != data {
            defaults.set(migrated, forKey: Key.snapshot)
        }
    }

    nonisolated static func decodeAndMigrate(
        _ data: Data
    ) throws -> Chapter01ProgressSnapshot {
        let decoder = JSONDecoder()
        if var current = try? decoder.decode(Chapter01ProgressSnapshot.self, from: data),
           current.schemaVersion == Chapter01ProgressSnapshot.currentSchemaVersion {
            // The first Four Chances build could persist the post-Robot
            // checkpoint before its hub-unlocked bit. That combination is not
            // a valid destination. Repair that single saved record in place so
            // Continue restores the three pending branches without replaying
            // the Robot encounter or rescanning the room.
            if current.checkpoint >= .antigenGranted,
               !current.postRobot.unlocked {
                current.checkpoint = .postRobotHub
                current.postRobot.unlocked = true
                current.revision += 1
                current.committedAt = Date()
                current.contentRevision = contentRevision
            }
            let normalized = current.postRobot.normalizedForSequentialUnlock()
            if normalized != current.postRobot {
                current.postRobot = normalized
                current.checkpoint = normalized.allBranchesComplete
                    ? .preDadFinalBattleReady
                    : .postRobotHub
                current.revision += 1
                current.committedAt = Date()
            }
            return current
        }
        if let legacy = try? decoder.decode(LegacyV2Snapshot.self, from: data),
           legacy.schemaVersion == 2 {
            let postRobot = legacy.postRobot.normalizedForSequentialUnlock()
            let allComplete = postRobot.allBranchesComplete
            return Chapter01ProgressSnapshot(
                schemaVersion: Chapter01ProgressSnapshot.currentSchemaVersion,
                checkpoint: allComplete ? .preDadFinalBattleReady : .postRobotHub,
                postRobot: postRobot,
                revision: legacy.revision,
                sourceEventIDs: legacy.sourceEventIDs,
                committedAt: legacy.committedAt,
                contentRevision: contentRevision
            )
        }

        let legacy = try decoder.decode(LegacyV1Snapshot.self, from: data)
        let unlockHub = legacy.checkpoint >= .antigenGranted
        return Chapter01ProgressSnapshot(
            schemaVersion: Chapter01ProgressSnapshot.currentSchemaVersion,
            checkpoint: unlockHub ? .postRobotHub : legacy.checkpoint,
            postRobot: Chapter01PostRobotProgress(
                unlocked: unlockHub,
                completedBranches: []
            ),
            revision: legacy.revision,
            sourceEventIDs: [legacy.sourceEventID],
            committedAt: legacy.committedAt,
            contentRevision: contentRevision
        )
    }

    @discardableResult
    func commit(
        _ checkpoint: Chapter01Checkpoint,
        sourceEventID: UUID
    ) throws -> Chapter01ProgressSnapshot {
        if let snapshot, snapshot.sourceEventIDs.contains(sourceEventID) {
            return snapshot
        }
        if let snapshot, checkpoint < snapshot.checkpoint {
            return snapshot
        }
        var next = snapshot ?? Chapter01ProgressSnapshot(
            schemaVersion: Chapter01ProgressSnapshot.currentSchemaVersion,
            checkpoint: .root,
            postRobot: .locked,
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
        print("[Chapter01Progress] committed checkpoint=\(checkpoint.rawValue) revision=\(next.revision)")
        return next
    }

    @discardableResult
    func unlockPostRobotHub(
        sourceEventID: UUID
    ) throws -> Chapter01ProgressSnapshot {
        if let snapshot,
           snapshot.postRobot.unlocked,
           snapshot.sourceEventIDs.contains(sourceEventID) {
            return snapshot
        }
        var next = snapshot ?? Chapter01ProgressSnapshot(
            schemaVersion: Chapter01ProgressSnapshot.currentSchemaVersion,
            checkpoint: .postRobotHub,
            postRobot: .locked,
            revision: 0,
            sourceEventIDs: [],
            committedAt: Date(),
            contentRevision: Self.contentRevision
        )
        next.postRobot.unlocked = true
        next.checkpoint = next.postRobot.allBranchesComplete
            ? .preDadFinalBattleReady
            : .postRobotHub
        next.sourceEventIDs.insert(sourceEventID)
        next.revision += 1
        next.committedAt = Date()
        try persist(next)
        print("[Chapter01Progress] post-Robot hub unlocked revision=\(next.revision)")
        return next
    }

    func completePostRobotBranch(
        _ branch: Chapter01PostRobotBranch,
        terminalScriptPointID: String,
        sourceEventID: UUID
    ) throws -> Chapter01PostRobotBranchCompletionResult {
        guard var next = snapshot else {
            throw Chapter01Error.postRobotHubNotUnlocked
        }
        guard next.postRobot.unlocked else {
            throw Chapter01Error.postRobotHubNotUnlocked
        }
        guard branch.terminalScriptPointID == terminalScriptPointID else {
            throw Chapter01Error.terminalPointMismatch
        }
        guard next.postRobot.isAvailable(branch) else {
            throw Chapter01Error.postRobotBranchNotAvailable(branch)
        }
        if next.sourceEventIDs.contains(sourceEventID) {
            return Chapter01PostRobotBranchCompletionResult(
                snapshot: next,
                branch: branch,
                wasNewlyCompleted: false,
                becameAllBranchesComplete: false
            )
        }
        if next.postRobot.completedBranches.contains(branch) {
            return Chapter01PostRobotBranchCompletionResult(
                snapshot: next,
                branch: branch,
                wasNewlyCompleted: false,
                becameAllBranchesComplete: false
            )
        }

        let wasComplete = next.postRobot.allBranchesComplete
        let inserted = next.postRobot.completedBranches.insert(branch).inserted
        next.sourceEventIDs.insert(sourceEventID)
        next.checkpoint = next.postRobot.allBranchesComplete
            ? .preDadFinalBattleReady
            : .postRobotHub
        next.revision += 1
        next.committedAt = Date()
        try persist(next)
        return Chapter01PostRobotBranchCompletionResult(
            snapshot: next,
            branch: branch,
            wasNewlyCompleted: inserted,
            becameAllBranchesComplete: !wasComplete && next.postRobot.allBranchesComplete
        )
    }

    func currentSnapshot() -> Chapter01ProgressSnapshot? { snapshot }

    func clear(reason: String) {
        defaults.removeObject(forKey: Key.snapshot)
        snapshot = nil
        NotificationCenter.default.post(
            name: .chapter01ProgressDidChange,
            object: nil
        )
        print("[Chapter01Progress] cleared reason=\(reason)")
    }

    @discardableResult
    func resetForReplay(
        sourceEventID: UUID
    ) throws -> Chapter01ProgressSnapshot {
        clear(reason: "chapter01Replay")
        return try commit(.root, sourceEventID: sourceEventID)
    }

    private func persist(_ next: Chapter01ProgressSnapshot) throws {
        defaults.set(try JSONEncoder().encode(next), forKey: Key.snapshot)
        snapshot = next
        NotificationCenter.default.post(
            name: .chapter01ProgressDidChange,
            object: nil
        )
    }
}
