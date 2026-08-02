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
    case dadFinalBattle
    case finalDadFramePending
    case complete
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
    case postRobotBranchNotAvailable(Chapter01PostRobotBranch)
    case terminalPointMismatch
    case robotReleaseBoundaryFailed
    case invalidFinalDadFrameTransition
    case finalDadFrameNotPending
    case finalDadFramePresentationFailed
    case wrongFinalScriptPoint
    case dadFinalBattleReleaseBoundaryFailed
    case staleDadFinalBattleCompletion
    case missingDadFinalBattleCompletionSink

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
        case .postRobotBranchNotAvailable(let branch):
            return "The Chapter 01 \(branch.rawValue) interaction is not available yet."
        case .terminalPointMismatch:
            return "A Chapter 01 branch completed from the wrong terminal ScriptPoint."
        case .robotReleaseBoundaryFailed:
            return "The Robot, its audio, or the exterior portal is still resident."
        case .invalidFinalDadFrameTransition:
            return "Chapter 01 cannot unlock the final Dad-frame memory from its current checkpoint."
        case .finalDadFrameNotPending:
            return "The final Dad-frame memory is not pending."
        case .finalDadFramePresentationFailed:
            return "The final Dad-frame interaction could not become the active Chapter action."
        case .wrongFinalScriptPoint:
            return "Chapter 01 completed from the wrong final ScriptPoint."
        case .dadFinalBattleReleaseBoundaryFailed:
            return "The Dad battle, its audio, or the exterior portal is still resident."
        case .staleDadFinalBattleCompletion:
            return "Chapter 01 received a stale Dad final-battle completion."
        case .missingDadFinalBattleCompletionSink:
            return "The Dad final battle has no Chapter completion sink."
        }
    }
}
