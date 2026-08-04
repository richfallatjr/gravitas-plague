import Foundation

nonisolated struct TuringExternalActivationContext: Sendable, Hashable {
    let activationID: UUID
    let scope: String
    let subjectID: String

    static func prologuePostBattleDevice(
        _ deviceID: ProloguePostBattleDeviceID,
        activationID: UUID = UUID()
    ) -> Self {
        .init(
            activationID: activationID,
            scope: "prologuePostBattleDevice",
            subjectID: deviceID.rawValue
        )
    }
}

nonisolated enum ProloguePostBattleActivationError: LocalizedError {
    case playCapabilityMissing(ProloguePostBattleDeviceID)
    case invalidActivationContext
    case completionWithoutAcceptedActivation
    case wrongTerminalScriptPoint
    case wrongTriggerProvenance
    case terminalPlaybackIncomplete
    case duplicateCompletion

    var errorDescription: String? {
        switch self {
        case .playCapabilityMissing(let device):
            return "The Play capability for \(device.rawValue) is unavailable."
        case .invalidActivationContext:
            return "The Prologue device activation context is invalid."
        case .completionWithoutAcceptedActivation:
            return "Device completion did not belong to an accepted Play action."
        case .wrongTerminalScriptPoint:
            return "Device completion used the wrong terminal ScriptPoint."
        case .wrongTriggerProvenance:
            return "Device completion used the wrong authored trigger chain."
        case .terminalPlaybackIncomplete:
            return "Device completion arrived before actual terminal playback completed."
        case .duplicateCompletion:
            return "Device completion event was already consumed."
        }
    }
}

actor TuringProloguePostBattleActivationRegistry {
    static let shared = TuringProloguePostBattleActivationRegistry()

    struct Record: Sendable, Equatable {
        let deviceID: ProloguePostBattleDeviceID
        let activationID: UUID
        let rootScriptPointID: String
        let expectedTerminalScriptPointID: String
        let flowSequenceID: UUID
        let acceptedAt: Date
    }

    private let progress: TuringProloguePostBattleProgressStore
    private let arbiter: StoryInteractionArbiter
    private var recordsByActivationID: [UUID: Record] = [:]
    private var consumedCompletionEventIDs = Set<UUID>()

    init(
        progress: TuringProloguePostBattleProgressStore = .shared,
        arbiter: StoryInteractionArbiter = .shared
    ) {
        self.progress = progress
        self.arbiter = arbiter
    }

    func prepareIfNeeded(
        rootScriptPointID: String,
        trigger: TuringFlowTriggerSource
    ) async throws -> TuringExternalActivationContext? {
        guard case .userPlay = trigger,
              let contract = TuringProloguePostBattleDeviceCatalog
                .byRootScriptPointID[rootScriptPointID] else {
            return nil
        }

        _ = try await progress.requirePlayable(contract.deviceID)
        let interaction = await arbiter.currentSnapshot()
        guard interaction.capabilities.contains(contract.playCapability) else {
            throw ProloguePostBattleActivationError
                .playCapabilityMissing(contract.deviceID)
        }
        return .prologuePostBattleDevice(contract.deviceID)
    }

    func registerAcceptedPlay(
        _ context: TuringExternalActivationContext,
        flowSequenceID: UUID
    ) async throws {
        guard context.scope == "prologuePostBattleDevice",
              let deviceID = ProloguePostBattleDeviceID(
                rawValue: context.subjectID
              ),
              let contract = TuringProloguePostBattleDeviceCatalog.byID[deviceID]
        else {
            throw ProloguePostBattleActivationError.invalidActivationContext
        }
        _ = try await progress.requirePlayable(deviceID)
        recordsByActivationID[context.activationID] = Record(
            deviceID: deviceID,
            activationID: context.activationID,
            rootScriptPointID: contract.rootScriptPointID,
            expectedTerminalScriptPointID: contract.terminalScriptPointID,
            flowSequenceID: flowSequenceID,
            acceptedAt: Date()
        )
        print("""
        [ProloguePostBattleHub]
          operation: activationAccepted
          deviceID: \(deviceID.rawValue)
          activationID: \(context.activationID.uuidString)
          flowSequenceID: \(flowSequenceID.uuidString)
          rootScriptPointID: \(contract.rootScriptPointID)
          terminalScriptPointID: \(contract.terminalScriptPointID)
          acceptedAt: \(recordsByActivationID[context.activationID]?.acceptedAt.description ?? "nil")
        """)
    }

    func consumeValidatedCompletion(
        event: TuringScriptPointCompletionEvent,
        contract: ProloguePostBattleDeviceContract
    ) throws -> Record {
        guard event.actualPlaybackCompleted else {
            throw ProloguePostBattleActivationError.terminalPlaybackIncomplete
        }
        guard event.scriptPointID == contract.terminalScriptPointID else {
            throw ProloguePostBattleActivationError.wrongTerminalScriptPoint
        }
        guard let external = event.externalActivation,
              external.scope == "prologuePostBattleDevice",
              external.subjectID == contract.deviceID.rawValue,
              let record = recordsByActivationID[external.activationID],
              record.deviceID == contract.deviceID,
              record.flowSequenceID == event.flowSequenceID else {
            throw ProloguePostBattleActivationError
                .completionWithoutAcceptedActivation
        }
        guard contract.terminalTrigger.matches(event.triggerSource) else {
            throw ProloguePostBattleActivationError.wrongTriggerProvenance
        }
        guard consumedCompletionEventIDs.insert(event.eventID).inserted else {
            throw ProloguePostBattleActivationError.duplicateCompletion
        }
        recordsByActivationID.removeValue(forKey: external.activationID)
        return record
    }

    func cancel(
        _ context: TuringExternalActivationContext,
        reason: String
    ) {
        guard recordsByActivationID.removeValue(
            forKey: context.activationID
        ) != nil else {
            return
        }
        print("""
        [ProloguePostBattleHub]
          operation: activationFailed
          activationID: \(context.activationID.uuidString)
          reason: \(reason)
        """)
    }

    func reset(reason: String) {
        recordsByActivationID.removeAll(keepingCapacity: false)
        consumedCompletionEventIDs.removeAll(keepingCapacity: false)
        print("[TuringProloguePostBattle] activation registry reset reason=\(reason)")
    }
}
