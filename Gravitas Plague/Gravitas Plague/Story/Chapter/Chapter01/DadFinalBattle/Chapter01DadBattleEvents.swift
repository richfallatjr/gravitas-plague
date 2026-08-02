import Foundation

enum Chapter01DadFinalBattleState: String, Sendable {
    case unloaded
    case preparing
    case portalIdleFacingAway
    case turnOne
    case turnTwo
    case approachingDoor
    case waitingForDoor
    case openingDoor
    case portalCrossing
    case combatGracePeriod
    case combatLethal
    case dadDeathAnimation
    case dadDeathDialogueHold
    case playerDead
    case releasingRuntime
    case postBattleHold
    case failed
    case cancelled
}

enum ChapterPlayerDeathSource: String, Sendable {
    case robot
    case dadFinalBattle
}

struct Chapter01DadFinalBattleReleasedEvent: Sendable, Equatable {
    let eventID: UUID
    let chapterRunID: UUID
    let battleInstanceID: UUID
    let releaseReport: BattleRuntimeReleaseReport
}
