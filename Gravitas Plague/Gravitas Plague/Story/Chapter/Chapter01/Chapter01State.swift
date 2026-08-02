import Foundation

enum Chapter01State: Sendable, Equatable {
    case idle
    case rootReady
    case script06
    case script07
    case dadWindow
    case robot
    case postRobotHub
    case preDadFinalBattleReady
    case failed(String)
    case cancelled
}

enum Chapter01Error: LocalizedError {
    case missingRun
    case staleDadEvent
    case unexpectedConversationCompletion
    case stageNotEstablished
    case unsupportedContinuationCheckpoint
    case openingResourceUnavailable(String)
    case postRobotHubNotUnlocked
    case terminalPointMismatch
    case robotReleaseBoundaryFailed

    var errorDescription: String? {
        switch self {
        case .missingRun:
            return "Chapter 01 has no active run."
        case .staleDadEvent:
            return "Chapter 01 received a stale Dad-window event."
        case .unexpectedConversationCompletion:
            return "Chapter 01 Script06 and Script07 do not accept conversation playback."
        case .stageNotEstablished:
            return "The Story room must be established before Chapter 01 starts."
        case .unsupportedContinuationCheckpoint:
            return "Chapter 01 has no supported continuation checkpoint."
        case .openingResourceUnavailable(let detail):
            return "Chapter 01 opening is unavailable: \(detail)"
        case .postRobotHubNotUnlocked:
            return "The Chapter 01 post-Robot hub is not unlocked."
        case .terminalPointMismatch:
            return "A Chapter 01 branch completed from the wrong terminal ScriptPoint."
        case .robotReleaseBoundaryFailed:
            return "The Robot, its audio, or the exterior portal is still resident."
        }
    }
}
