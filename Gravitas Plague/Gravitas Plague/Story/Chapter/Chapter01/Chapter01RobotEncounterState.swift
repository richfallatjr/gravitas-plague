import Foundation

enum Chapter01RobotEncounterState: Sendable, Equatable {
    case unloaded
    case preparingExterior
    case preparingRobot
    case exteriorIdle
    case openingDoor
    case enteringPortal
    case approachingPlayer
    case arrivedIdle
    case scanInstructionPR
    case initialCompliance
    case complianceWarningPR
    case attackingNoncompliance
    case stabilityRecovery
    case complianceRestoredPR
    case successfulScanPR
    case rewarding(source: StoryRewardSource)
    case exitConfirmationPR
    case walkingToDoor
    case exitingPortal
    case robotDeathAnimation
    case payloadReleasePR
    case releasing
    case released
    case playerDead
    case failed(message: String)
    case cancelled
}

struct Chapter01RobotEncounterCompletionEvent: Sendable {
    let chapterRunID: UUID
    let rewardSource: StoryRewardSource
    let releaseReport: Chapter01RobotReleaseReport
    let postRobotTransitionLease: StoryInteractionLease
}

struct Chapter01RobotEncounterFailureEvent: Sendable {
    let chapterRunID: UUID
    let message: String
    let retryCheckpointID: String
}

@MainActor
protocol Chapter01RobotEncounterCompletionSink: AnyObject {
    func robotEncounterCompleted(
        _ event: Chapter01RobotEncounterCompletionEvent
    ) async throws

    func robotEncounterFailed(
        _ event: Chapter01RobotEncounterFailureEvent
    ) async
}

struct Chapter01RobotEncounterRequest {
    let chapterRunID: UUID
    let battleLease: StoryInteractionLease
    let completionSink: any Chapter01RobotEncounterCompletionSink
}

@MainActor
protocol Chapter01RobotEncounterControlling: AnyObject {
    func validateAvailability() async throws
    func start(request: Chapter01RobotEncounterRequest) async throws
    func cancel(reason: String) async
    func reset(reason: String) async
    func update(deltaTime: TimeInterval)
    var hasActiveHeavyRuntime: Bool { get }
}
