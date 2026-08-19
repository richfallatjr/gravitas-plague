import Foundation

@MainActor
struct TuringLiveConversationSession {
    let sessionID: UUID
    let generation: UInt64
    let parentFlowSequenceID: UUID
    let parentFlowInstanceID: UUID
    let parentPlaybackRunID: String
    let parentLease: StoryInteractionLease
    let authoredPlayback: any TuringFlowPlaybackControlling
    var progressionHold: TuringAuthoredProgressionHoldToken?
    var activeTurnID: UUID?
}

@MainActor
final class TuringLiveConversationTurn {
    enum State: Sendable, Equatable {
        case dictating
        case submitted
        case computing
        case waitingForCover
        case playing
        case completed
        case failed
        case cancelled
    }

    let turnID: UUID
    let selectedSurface: StoryInteractionSurfaceID
    let seed: TuringLiveConversationSeed
    let computeToken: TuringLiveConversationComputeAdmission.Token
    let childToken: StoryLiveConversationChildToken
    let coverReceipt: TuringSpokenCoverPauseReceipt
    let coverPlayback: any TuringSpokenCoverControlling
    let playbackGate: TuringConversationPlaybackStartGate
    let dictation: TuringDictationCoordinator
    let previousDictationEventHandler: ((TuringDictationEvent) -> Void)?

    var state: State = .dictating
    var question: String?
    var segmentZeroPrepared = false
    var allComputeFinished = false
    var coverCompleted = false
    var responseStarted = false
    var responseCompleted = false
    var responsePlayback: (any TuringFlowPlaybackControlling)?
    var childReleased = false
    var initialFillerToken: TuringLiveConversationInitialFillerToken?
    var questionTimer: Task<Void, Never>?
    var coverWaiter: Task<Void, Never>?
    var responseTask: Task<Void, Never>?
    var dictationEventHandlerRestored = false

    init(
        turnID: UUID,
        selectedSurface: StoryInteractionSurfaceID,
        seed: TuringLiveConversationSeed,
        computeToken: TuringLiveConversationComputeAdmission.Token,
        childToken: StoryLiveConversationChildToken,
        coverReceipt: TuringSpokenCoverPauseReceipt,
        coverPlayback: any TuringSpokenCoverControlling,
        playbackGate: TuringConversationPlaybackStartGate,
        dictation: TuringDictationCoordinator,
        previousDictationEventHandler: ((TuringDictationEvent) -> Void)?
    ) {
        self.turnID = turnID
        self.selectedSurface = selectedSurface
        self.seed = seed
        self.computeToken = computeToken
        self.childToken = childToken
        self.coverReceipt = coverReceipt
        self.coverPlayback = coverPlayback
        self.playbackGate = playbackGate
        self.dictation = dictation
        self.previousDictationEventHandler = previousDictationEventHandler
    }
}
