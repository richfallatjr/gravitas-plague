import Foundation

enum Chapter01RobotCleanupOutcome: Sendable, Equatable {
    case rewardedRobotDeparted
    case rewardedRobotDestroyed
    case playerDeadBeforeReward
    case retryableFailure
    case cancelled
    case storyTeardown
    case immersiveTeardown

    var battleReleaseReason: BattleEnemyReleaseReason {
        switch self {
        case .rewardedRobotDeparted, .rewardedRobotDestroyed:
            return .battleCompleted
        case .playerDeadBeforeReward, .retryableFailure:
            return .battleCancelled
        case .cancelled:
            return .battleCancelled
        case .storyTeardown:
            return .storyReset
        case .immersiveTeardown:
            return .immersiveShutdown
        }
    }
}

struct Chapter01RobotReleaseReport: Sendable {
    let chapterRunID: UUID
    let outcome: Chapter01RobotCleanupOutcome
    let dadRuntimeCount: Int
    let robotRuntimeCount: Int
    let preparedClipCount: Int
    let portalMirrorCount: Int
    let fullExteriorResident: Bool
    let doorState: StoryDoorLifecycleState
    let robotSpeechHandleCount: Int
    let robotCombatHandleCount: Int
    let activeEncounterTaskCount: Int
    let weakRobotControllerReleased: Bool
    let physicalFootprintMB: UInt64
    let residentSizeMB: UInt64

    var isSafeForTuring: Bool {
        dadRuntimeCount == 0 &&
            robotRuntimeCount == 0 &&
            preparedClipCount == 0 &&
            portalMirrorCount == 0 &&
            !fullExteriorResident &&
            doorState == .closedUnloaded &&
            robotSpeechHandleCount == 0 &&
            robotCombatHandleCount == 0 &&
            activeEncounterTaskCount == 0 &&
            weakRobotControllerReleased
    }
}
