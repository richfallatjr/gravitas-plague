import Foundation

struct RestoredPendingConversationAdvance: Sendable, Equatable {
    let parentScriptPointID: String
    let nextScriptPointID: String
    let conversationKey: String
}

struct TuringStoryDestination: Sendable, Equatable {
    let episodeID: TuringEpisodeID
    let checkpoint: TuringPrologueCheckpoint
    let completedScriptPointIDs: Set<String>
    let pendingConversationAdvance: RestoredPendingConversationAdvance?
    let walkieAction: TuringStoryWalkieDestination
    let doorState: TuringStoryDoorDestination?
    let battleState: TuringStoryBattleDestination
    let mediaState: TuringStoryMediaDestination
}

enum TuringStoryWalkieDestination: Sendable, Equatable {
    case play(scriptPointID: String, trigger: TuringFlowTriggerSource)
    case microphone
    case hidden
}

enum TuringStoryDoorDestination: Sendable, Equatable {
    case closed
    case open
}

enum TuringStoryBattleDestination: Sendable, Equatable {
    case absent
    case battle01Ready
    case battle01Start
    case battle01Combat
    case battle01GrandmaDown
}

enum TuringStoryMediaDestination: Sendable, Equatable {
    case silent
    case battle01
    case battle01Aftermath
}

enum TuringStoryContinuationError: LocalizedError {
    case anotherRequestActive
    case noValidSnapshot
    case contentRevisionMismatch
    case storyStageNotEstablished
    case teleportAlreadyActive
    case missingWorldAdapter
    case unsupportedEpisode
    case establishedLayoutChanged

    var errorDescription: String? {
        switch self {
        case .anotherRequestActive:
            return "Another Story request is already active."
        case .noValidSnapshot:
            return "No valid Story checkpoint is available."
        case .contentRevisionMismatch:
            return "Saved Story progress is not compatible with this build."
        case .storyStageNotEstablished:
            return "The Story room has not been established."
        case .teleportAlreadyActive:
            return "Another Story state change is already active."
        case .missingWorldAdapter:
            return "The Story world did not install its state adapter."
        case .unsupportedEpisode:
            return "This episode is not available."
        case .establishedLayoutChanged:
            return "Story state restoration attempted to move the established room layout."
        }
    }
}
