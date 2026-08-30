import Foundation

enum StoryTuringGateState: String, Sendable, Equatable {
    case closed
    case play
    case busy
    case microphone
}

nonisolated enum StoryTuringActionPresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
    case microphoneRecovering
    case microphoneUnavailable
}

nonisolated enum StoryTuringActivityPresentation: String, Sendable, Equatable {
    case hidden
    case authoredPlaying
    case processingEllipsis
    case conversationPlaying
}

nonisolated struct StoryMicrophoneCTAEmphasis:
    Sendable,
    Equatable,
    Hashable
{
    let saturation: Float

    init(saturation: Float) {
        self.saturation = min(1, max(0, saturation))
    }

    static let saturated = StoryMicrophoneCTAEmphasis(saturation: 1)
    static let desaturated = StoryMicrophoneCTAEmphasis(saturation: 0)

    var isEndpoint: Bool {
        saturation == 0 || saturation == 1
    }

    var rawValue: String {
        "saturation_\(Int((saturation * 1_000).rounded()))"
    }
}

nonisolated struct StoryTuringSurfacePresentation: Sendable, Equatable {
    let action: StoryTuringActionPresentation
    let activity: StoryTuringActivityPresentation
    let microphoneCTAEmphasis: StoryMicrophoneCTAEmphasis

    init(
        action: StoryTuringActionPresentation,
        activity: StoryTuringActivityPresentation,
        microphoneCTAEmphasis: StoryMicrophoneCTAEmphasis = .saturated
    ) {
        self.action = action
        self.activity = activity
        self.microphoneCTAEmphasis = microphoneCTAEmphasis
    }

    static let hidden = StoryTuringSurfacePresentation(
        action: .hidden,
        activity: .hidden
    )
}

nonisolated struct StoryLiveConversationChildToken:
    Sendable,
    Equatable,
    Hashable
{
    let id: UUID
    let sessionID: UUID
    let turnID: UUID
    let parentLeaseID: UUID
    let selectedSurface: StoryInteractionSurfaceID
}

nonisolated struct TuringLatchedMicrophoneSlot: Sendable, Equatable {
    let slotID: UUID
    let generation: UInt64
    let episodeID: TuringEpisodeID
    let segmentID: String
    let surface: StoryInteractionSurfaceID
    let activationMomentID: String
    let targetCharacterID: TuringConversationCharacterID
    let seed: TuringLiveConversationSeed
}

nonisolated enum TuringConversationMicrophoneBoundary:
    Sendable,
    Equatable
{
    case chapter(TuringEpisodeID)
    case battle(UUID)
    case antigenDroneSequence(UUID)
    case startOver(TuringEpisodeID)
    case teardown

    var logValue: String {
        switch self {
        case .chapter(let episodeID):
            return "chapter.\(episodeID.rawValue)"
        case .battle(let id):
            return "battle.\(id.uuidString)"
        case .antigenDroneSequence(let id):
            return "antigenDroneSequence.\(id.uuidString)"
        case .startOver(let episodeID):
            return "startOver.\(episodeID.rawValue)"
        case .teardown:
            return "teardown"
        }
    }
}

nonisolated enum StoryInteractionSurfaceID:
    String,
    Codable,
    Sendable,
    Hashable,
    CaseIterable
{
    case walkie
    case dadFrame
    case crankRadio
    case hamReceiver
}

enum StoryStableInteractionPolicyID:
    String,
    Codable,
    Sendable,
    Equatable
{
    case unrestricted
    case chapter01FinalDadFrameOnly
}

struct StoryStableInteractionPolicy: Sendable, Equatable {
    let id: StoryStableInteractionPolicyID
    let allowedTuringSurfaces: Set<StoryInteractionSurfaceID>
    let permitsDoorInteraction: Bool

    static let unrestricted = Self(
        id: .unrestricted,
        allowedTuringSurfaces: Set(StoryInteractionSurfaceID.allCases),
        permitsDoorInteraction: true
    )

    static let chapter01FinalDadFrameOnly = Self(
        id: .chapter01FinalDadFrameOnly,
        allowedTuringSurfaces: [.dadFrame],
        permitsDoorInteraction: false
    )
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

nonisolated enum StoryInteractionCapability: String, Sendable, Hashable {
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
    case microphoneRecovering
    case microphoneUnavailable
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
    case microphoneRecovering
    case microphoneUnavailable
}

enum StoryCrankRadioPresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
    case microphoneRecovering
    case microphoneUnavailable
}

enum StoryHamReceiverPresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
    case microphoneRecovering
    case microphoneUnavailable
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
    let turingSurfacePresentations:
        [StoryInteractionSurfaceID: StoryTuringSurfacePresentation]

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
            StoryHamReceiverPresentation = .hidden,
        turingSurfacePresentations:
            [StoryInteractionSurfaceID: StoryTuringSurfacePresentation] = [:]
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
        self.turingSurfacePresentations = turingSurfacePresentations
    }
}

enum StoryInteractionClaimError: LocalizedError, Sendable, Equatable {
    case exclusiveOwnerActive
    case turingGateNotInteractive
    case doorNotClosedAndUnloaded
    case staleLease
    case invalidTransfer
    case interactionNotPermitted

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
        case .interactionNotPermitted:
            return "The requested Story interaction is not permitted in the current Chapter state."
        }
    }
}

enum TuringInteractionStartMode: Sendable {
    case manual
    case automatic
}
