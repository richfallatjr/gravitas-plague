import Foundation

nonisolated enum ProloguePostBattleDeviceState: String, Codable, Sendable, Equatable {
    case play
    case microphone
}

nonisolated enum ProloguePostBattleBoundaryState: String, Codable, Sendable, Equatable {
    case notReady
    case chapterTransitionPending
    case chapter01Started
}

nonisolated enum ProloguePostBattleCompletionEvidence: Codable, Sendable, Equatable {
    case live(Live)
    case trustedLegacyMigration(TrustedLegacyMigration)

    struct Live: Codable, Sendable, Equatable {
        let deviceID: ProloguePostBattleDeviceID
        let rootScriptPointID: String
        let terminalScriptPointID: String
        let activationID: UUID
        let flowSequenceID: UUID
        let flowInstanceID: UUID
        let terminalCompletionEventID: UUID
        let triggerDescription: String
        let actualTerminalPlaybackCompletedAt: Date
    }

    struct TrustedLegacyMigration: Codable, Sendable, Equatable {
        let deviceID: ProloguePostBattleDeviceID
        let migrationID: UUID
        let legacySchemaVersion: Int
        let legacyContentRevision: String
        let migratedAt: Date
        let reason: String
    }

    var deviceID: ProloguePostBattleDeviceID {
        switch self {
        case .live(let value):
            return value.deviceID
        case .trustedLegacyMigration(let value):
            return value.deviceID
        }
    }

    var terminalCompletionEventID: UUID? {
        guard case .live(let value) = self else { return nil }
        return value.terminalCompletionEventID
    }
}

nonisolated struct ProloguePostBattleSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2
    static let currentContentRevision = "prologue.postBattleHub.v2"

    let schemaVersion: Int
    let contentRevision: String
    var hubUnlocked: Bool
    var deviceStates: [ProloguePostBattleDeviceID: ProloguePostBattleDeviceState]
    var completionEvidence:
        [ProloguePostBattleDeviceID: ProloguePostBattleCompletionEvidence]
    var boundaryState: ProloguePostBattleBoundaryState
    var boundaryEventID: UUID?
    var revision: UInt64
    var committedAt: Date

    static func initialUnlocked(at date: Date) -> Self {
        .init(
            schemaVersion: currentSchemaVersion,
            contentRevision: currentContentRevision,
            hubUnlocked: true,
            deviceStates: Dictionary(
                uniqueKeysWithValues: ProloguePostBattleDeviceID.allCases.map {
                    ($0, .play)
                }
            ),
            completionEvidence: [:],
            boundaryState: .notReady,
            boundaryEventID: nil,
            revision: 1,
            committedAt: date
        )
    }

    var allDevicesCompleted: Bool {
        ProloguePostBattleDeviceID.allCases.allSatisfy {
            deviceStates[$0] == .microphone
        }
    }

    func state(
        for device: ProloguePostBattleDeviceID
    ) -> ProloguePostBattleDeviceState {
        deviceStates[device] ?? .play
    }

    func nextRequiredDevice(
        ordered contracts: [ProloguePostBattleDeviceContract]
    ) -> ProloguePostBattleDeviceID? {
        contracts.map(\.deviceID).first {
            state(for: $0) == .play
        }
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
              contentRevision == Self.currentContentRevision else {
            throw ProloguePostBattleProgressError.unsupportedSnapshot(
                schemaVersion: schemaVersion,
                contentRevision: contentRevision
            )
        }

        let expected = Set(ProloguePostBattleDeviceID.allCases)
        guard Set(deviceStates.keys) == expected else {
            throw ProloguePostBattleProgressError.incompleteDeviceMap
        }

        for device in expected {
            guard let state = deviceStates[device] else {
                throw ProloguePostBattleProgressError.incompleteDeviceMap
            }
            let evidence = completionEvidence[device]
            switch state {
            case .play:
                guard evidence == nil else {
                    throw ProloguePostBattleProgressError
                        .playStateHasCompletionEvidence(device)
                }
            case .microphone:
                guard evidence?.deviceID == device else {
                    throw ProloguePostBattleProgressError
                        .microphoneStateMissingEvidence(device)
                }
            }
        }

        switch boundaryState {
        case .notReady:
            guard allDevicesCompleted == false,
                  boundaryEventID == nil else {
                throw ProloguePostBattleProgressError.invalidNotReadyBoundary
            }
        case .chapterTransitionPending:
            guard allDevicesCompleted,
                  boundaryEventID != nil else {
                throw ProloguePostBattleProgressError.invalidPendingBoundary
            }
        case .chapter01Started:
            guard allDevicesCompleted,
                  boundaryEventID != nil else {
                throw ProloguePostBattleProgressError.invalidChapterStartedBoundary
            }
        }
        return self
    }
}

nonisolated struct ProloguePostBattleCompletionTransaction: Sendable, Equatable {
    let snapshot: ProloguePostBattleSnapshot
    let deviceWasNewlyCompleted: Bool
    let becameChapterTransitionPending: Bool
    let boundaryEvent: StoryEpisodeBoundaryEvent?
}

nonisolated enum ProloguePostBattleProgressError: LocalizedError {
    case unsupportedSnapshot(schemaVersion: Int, contentRevision: String)
    case incompleteDeviceMap
    case playStateHasCompletionEvidence(ProloguePostBattleDeviceID)
    case microphoneStateMissingEvidence(ProloguePostBattleDeviceID)
    case invalidNotReadyBoundary
    case invalidPendingBoundary
    case invalidChapterStartedBoundary
    case hubNotUnlocked
    case deviceNotPlayable(ProloguePostBattleDeviceID)
    case snapshotMissing
    case invalidChapterStartCommit
    case unsupportedLegacySnapshot(schemaVersion: Int, contentRevision: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSnapshot(let version, let revision):
            return "Unsupported Prologue post-battle snapshot \(version)/\(revision)."
        case .incompleteDeviceMap:
            return "Prologue post-battle snapshot does not contain all four devices."
        case .playStateHasCompletionEvidence(let device):
            return "Play-state device \(device.rawValue) has completion evidence."
        case .microphoneStateMissingEvidence(let device):
            return "Microphone-state device \(device.rawValue) has no completion evidence."
        case .invalidNotReadyBoundary:
            return "Prologue not-ready boundary is inconsistent with device progress."
        case .invalidPendingBoundary:
            return "Prologue pending boundary is incomplete."
        case .invalidChapterStartedBoundary:
            return "Prologue Chapter-started boundary is incomplete."
        case .hubNotUnlocked:
            return "The Prologue post-battle devices are not unlocked."
        case .deviceNotPlayable(let device):
            return "The Prologue device \(device.rawValue) is not in Play state."
        case .snapshotMissing:
            return "The Prologue post-battle snapshot is missing."
        case .invalidChapterStartCommit:
            return "Chapter 1 cannot be committed from the current Prologue boundary."
        case .unsupportedLegacySnapshot(let version, let revision):
            return "Unsupported legacy Prologue post-battle snapshot \(version)/\(revision)."
        }
    }
}

actor TuringProloguePostBattleProgressStore {
    static let shared = TuringProloguePostBattleProgressStore()
    nonisolated static let saveKey =
        "turing.story.prologue.postBattleHub.snapshot.v2"
    nonisolated static let contentRevision =
        "prologue.postBattleHub.v2"

    private enum LegacyKey {
        static let snapshot = "story.prologue.postBattle.progress.v1"
    }

    private enum LegacyDevice: String, Codable, CaseIterable, Hashable {
        case walkie
        case crankRadio
        case dadPhoto
        case hamReceiver
    }

    private struct LegacyProgress: Codable {
        let unlocked: Bool
        let completedDevices: Set<LegacyDevice>
    }

    private struct LegacySnapshot: Codable {
        let schemaVersion: Int
        let progress: LegacyProgress
        let revision: Int
        let contentRevision: String
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> ProloguePostBattleSnapshot? {
        guard let data = defaults.data(forKey: Self.saveKey) else {
            return try migrateLegacyIfNeeded()
        }
        return try decoder.decode(
            ProloguePostBattleSnapshot.self,
            from: data
        ).validated()
    }

    @discardableResult
    func unlockAfterBattleRuntimeReleased() throws -> ProloguePostBattleSnapshot {
        if var existing = try load() {
            switch existing.boundaryState {
            case .chapter01Started:
                return existing
            case .notReady, .chapterTransitionPending:
                guard existing.hubUnlocked == false else { return existing }
                existing.hubUnlocked = true
                existing.revision += 1
                existing.committedAt = now()
                return try persist(existing)
            }
        }
        let initial = try persist(.initialUnlocked(at: now()))
        log(operation: "unlock", snapshot: initial)
        return initial
    }

    func requirePlayable(
        _ deviceID: ProloguePostBattleDeviceID
    ) throws -> ProloguePostBattleSnapshot {
        guard let snapshot = try load(), snapshot.hubUnlocked else {
            throw ProloguePostBattleProgressError.hubNotUnlocked
        }
        guard snapshot.boundaryState == .notReady,
              snapshot.deviceStates[deviceID] == .play,
              snapshot.nextRequiredDevice(
                ordered: TuringProloguePostBattleDeviceCatalog.ordered
              ) == deviceID else {
            throw ProloguePostBattleProgressError.deviceNotPlayable(deviceID)
        }
        return snapshot
    }

    func completeDevice(
        evidence: ProloguePostBattleCompletionEvidence.Live
    ) throws -> ProloguePostBattleCompletionTransaction {
        guard var snapshot = try load(), snapshot.hubUnlocked else {
            throw ProloguePostBattleProgressError.hubNotUnlocked
        }

        if snapshot.completionEvidence.values.contains(where: {
            $0.terminalCompletionEventID == evidence.terminalCompletionEventID
        }) {
            return .init(
                snapshot: snapshot,
                deviceWasNewlyCompleted: false,
                becameChapterTransitionPending: false,
                boundaryEvent: nil
            )
        }

        let device = evidence.deviceID
        guard snapshot.boundaryState == .notReady,
              snapshot.deviceStates[device] == .play else {
            throw ProloguePostBattleProgressError.deviceNotPlayable(device)
        }

        snapshot.deviceStates[device] = .microphone
        snapshot.completionEvidence[device] = .live(evidence)

        let becamePending = snapshot.allDevicesCompleted
        let boundaryEvent: StoryEpisodeBoundaryEvent?
        if becamePending {
            snapshot.boundaryState = .chapterTransitionPending
            snapshot.boundaryEventID = evidence.terminalCompletionEventID
            boundaryEvent = StoryEpisodeBoundaryEvent(
                eventID: evidence.terminalCompletionEventID,
                completedEpisodeID: .prologue,
                actualTerminalPlaybackCompleted: true
            )
        } else {
            boundaryEvent = nil
        }

        snapshot.revision += 1
        snapshot.committedAt = now()
        let committed = try persist(snapshot)
        log(
            operation: "deviceCompleted",
            snapshot: committed,
            liveEvidence: evidence
        )
        return .init(
            snapshot: committed,
            deviceWasNewlyCompleted: true,
            becameChapterTransitionPending: becamePending,
            boundaryEvent: boundaryEvent
        )
    }

    func markChapter01Started(
        boundaryEventID: UUID
    ) throws -> ProloguePostBattleSnapshot {
        guard var snapshot = try load() else {
            throw ProloguePostBattleProgressError.snapshotMissing
        }
        guard snapshot.boundaryState == .chapterTransitionPending,
              snapshot.boundaryEventID == boundaryEventID,
              snapshot.allDevicesCompleted else {
            throw ProloguePostBattleProgressError.invalidChapterStartCommit
        }
        snapshot.boundaryState = .chapter01Started
        snapshot.revision += 1
        snapshot.committedAt = now()
        let committed = try persist(snapshot)
        log(operation: "chapter01Started", snapshot: committed)
        return committed
    }

    func markPendingChapter01Started() throws -> ProloguePostBattleSnapshot {
        guard let snapshot = try load(),
              let boundaryEventID = snapshot.boundaryEventID else {
            throw ProloguePostBattleProgressError.snapshotMissing
        }
        if snapshot.boundaryState == .chapter01Started {
            return snapshot
        }
        return try markChapter01Started(boundaryEventID: boundaryEventID)
    }

    func clear(reason: String) {
        defaults.removeObject(forKey: Self.saveKey)
        defaults.removeObject(forKey: LegacyKey.snapshot)
        print("[TuringProloguePostBattle] cleared reason=\(reason)")
    }

    @discardableResult
    private func persist(
        _ snapshot: ProloguePostBattleSnapshot
    ) throws -> ProloguePostBattleSnapshot {
        let validated = try snapshot.validated()
        defaults.set(try encoder.encode(validated), forKey: Self.saveKey)
        return validated
    }

    private func migrateLegacyIfNeeded() throws -> ProloguePostBattleSnapshot? {
        guard let data = defaults.data(forKey: LegacyKey.snapshot) else {
            return nil
        }

        let legacy = try JSONDecoder().decode(LegacySnapshot.self, from: data)
        guard legacy.schemaVersion == 1,
              legacy.contentRevision == "prologue.postBattle.v3" else {
            throw ProloguePostBattleProgressError.unsupportedLegacySnapshot(
                schemaVersion: legacy.schemaVersion,
                contentRevision: legacy.contentRevision
            )
        }

        let date = now()
        let migrationID = UUID()
        var states = Dictionary(
            uniqueKeysWithValues: ProloguePostBattleDeviceID.allCases.map {
                ($0, ProloguePostBattleDeviceState.play)
            }
        )
        var evidence:
            [ProloguePostBattleDeviceID: ProloguePostBattleCompletionEvidence] = [:]
        for legacyDevice in legacy.progress.completedDevices {
            guard legacyDevice != .crankRadio,
                  let device = ProloguePostBattleDeviceID(
                    rawValue: legacyDevice.rawValue
                  ) else {
                continue
            }
            states[device] = .microphone
            evidence[device] = .trustedLegacyMigration(
                .init(
                    deviceID: device,
                    migrationID: migrationID,
                    legacySchemaVersion: legacy.schemaVersion,
                    legacyContentRevision: legacy.contentRevision,
                    migratedAt: date,
                    reason:
                        "Preserved trusted legacy device state; crank reset because validated activation evidence was absent."
                )
            )
        }

        states[.crankRadio] = .play
        evidence.removeValue(forKey: .crankRadio)
        let migrated = ProloguePostBattleSnapshot(
            schemaVersion: ProloguePostBattleSnapshot.currentSchemaVersion,
            contentRevision: ProloguePostBattleSnapshot.currentContentRevision,
            hubUnlocked: legacy.progress.unlocked,
            deviceStates: states,
            completionEvidence: evidence,
            boundaryState: .notReady,
            boundaryEventID: nil,
            revision: UInt64(max(legacy.revision, 0)) + 1,
            committedAt: date
        )
        let committed = try persist(migrated)
        defaults.removeObject(forKey: LegacyKey.snapshot)
        log(operation: "migrateLegacy", snapshot: committed)
        return committed
    }

    private func log(
        operation: String,
        snapshot: ProloguePostBattleSnapshot,
        liveEvidence: ProloguePostBattleCompletionEvidence.Live? = nil
    ) {
        print("""
        [ProloguePostBattleHub]
          operation: \(operation)
          snapshotRevision: \(snapshot.revision)
          hubUnlocked: \(snapshot.hubUnlocked)
          walkieState: \(snapshot.state(for: .walkie).rawValue)
          dadPhotoState: \(snapshot.state(for: .dadPhoto).rawValue)
          crankRadioState: \(snapshot.state(for: .crankRadio).rawValue)
          hamReceiverState: \(snapshot.state(for: .hamReceiver).rawValue)
          boundaryState: \(snapshot.boundaryState.rawValue)
          boundaryEventID: \(snapshot.boundaryEventID?.uuidString ?? "nil")
          deviceID: \(liveEvidence?.deviceID.rawValue ?? "nil")
          activationID: \(liveEvidence?.activationID.uuidString ?? "nil")
          flowSequenceID: \(liveEvidence?.flowSequenceID.uuidString ?? "nil")
          flowInstanceID: \(liveEvidence?.flowInstanceID.uuidString ?? "nil")
          terminalScriptPointID: \(liveEvidence?.terminalScriptPointID ?? "nil")
          terminalCompletionEventID: \(liveEvidence?.terminalCompletionEventID.uuidString ?? "nil")
          trigger: \(liveEvidence?.triggerDescription ?? "nil")
          persisted: true
        """)
    }
}
