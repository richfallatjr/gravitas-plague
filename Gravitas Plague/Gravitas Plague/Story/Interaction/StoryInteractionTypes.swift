import Foundation

enum StoryTuringGateState: String, Sendable, Equatable {
    case closed
    case play
    case busy
    case microphone
}

enum StoryInteractionSurfaceID:
    String,
    Codable,
    Sendable,
    Hashable
{
    case walkie
    case dadFrame
    case crankRadio
    case hamReceiver
}

enum StoryDoorLifecycleState: String, Sendable, Equatable {
    case closedUnloaded
    case loading
    case closedReady
    case opening
    case open
    case closing
    case unloading
    case failed
}

enum StoryBattleDoorPermission: String, Sendable, Equatable {
    case hiddenAndLocked
    case playerMayOpen
}

enum StoryInteractionCapability: String, Sendable, Hashable {
    case walkiePlay
    case walkieMicrophone
    case doorOpen
    case doorClose
    case crankRadioPlay
    case crankRadioMicrophone
    case hamReceiverPlay
    case hamReceiverMicrophone
    case handMicrophone
    case dadFramePlay
    case dadFrameMicrophone
}

enum StoryWalkiePresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
}

enum StoryDoorPresentation: String, Sendable, Equatable {
    case hidden
    case open
    case close
}

enum StoryDadFramePresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
}

enum StoryCrankRadioPresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
}

enum StoryHamReceiverPresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
}

enum StoryInteractionExclusiveOwner: Sendable, Hashable {
    case turingFlow(runID: String)
    case doorPortal(sessionID: UUID)
    case battle(battleInstanceID: UUID)
    case storyTransition(transitionID: UUID)

    var logValue: String {
        switch self {
        case .turingFlow(let runID):
            return "turingFlow.\(runID)"
        case .doorPortal(let sessionID):
            return "doorPortal.\(sessionID.uuidString)"
        case .battle(let battleInstanceID):
            return "battle.\(battleInstanceID.uuidString)"
        case .storyTransition(let transitionID):
            return "storyTransition.\(transitionID.uuidString)"
        }
    }
}

struct StoryInteractionLease: Hashable, Sendable {
    let id: UUID
    let owner: StoryInteractionExclusiveOwner
}

struct StoryInteractionSnapshot: Sendable, Equatable {
    let revision: UInt64
    let turingGate: StoryTuringGateState
    let doorState: StoryDoorLifecycleState
    let exclusiveOwner: StoryInteractionExclusiveOwner?
    let capabilities: Set<StoryInteractionCapability>
    let walkiePresentation: StoryWalkiePresentation
    let doorPresentation: StoryDoorPresentation
    let dadFramePresentation: StoryDadFramePresentation
    let crankRadioPresentation:
        StoryCrankRadioPresentation
    let hamReceiverPresentation:
        StoryHamReceiverPresentation

    init(
        revision: UInt64,
        turingGate: StoryTuringGateState,
        doorState: StoryDoorLifecycleState,
        exclusiveOwner: StoryInteractionExclusiveOwner?,
        capabilities: Set<StoryInteractionCapability>,
        walkiePresentation: StoryWalkiePresentation,
        doorPresentation: StoryDoorPresentation,
        dadFramePresentation: StoryDadFramePresentation = .hidden,
        crankRadioPresentation:
            StoryCrankRadioPresentation = .hidden,
        hamReceiverPresentation:
            StoryHamReceiverPresentation = .hidden
    ) {
        self.revision = revision
        self.turingGate = turingGate
        self.doorState = doorState
        self.exclusiveOwner = exclusiveOwner
        self.capabilities = capabilities
        self.walkiePresentation = walkiePresentation
        self.doorPresentation = doorPresentation
        self.dadFramePresentation = dadFramePresentation
        self.crankRadioPresentation =
            crankRadioPresentation
        self.hamReceiverPresentation =
            hamReceiverPresentation
    }
}

enum StoryInteractionClaimError: LocalizedError, Sendable, Equatable {
    case exclusiveOwnerActive
    case turingGateNotInteractive
    case doorNotClosedAndUnloaded
    case staleLease
    case invalidTransfer

    var errorDescription: String? {
        switch self {
        case .exclusiveOwnerActive:
            return "Another Story interaction is active."
        case .turingGateNotInteractive:
            return "The requested Story interaction is not available."
        case .doorNotClosedAndUnloaded:
            return "The door must be closed and its exterior unloaded."
        case .staleLease:
            return "The Story interaction lease is stale."
        case .invalidTransfer:
            return "The requested Story interaction ownership transfer is invalid."
        }
    }
}

enum TuringInteractionStartMode: Sendable {
    case manual
    case automatic
}
