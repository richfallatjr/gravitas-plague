import Foundation

enum Battle01State: String, Sendable {
    case unloaded
    case preparing
    case portalIdleFacingAway
    case turnOne
    case turnTwo
    case approachingDoor
    case waitingForDoor
    case openingDoor
    case portalCrossing
    case combat
    case grandmaDown
    case postBattleHold
    case failed
    case cancelled
}

enum Battle01Trigger: Sendable {
    case scriptPointCompleted(TuringScriptPointCompletionEvent)
    case continuationRestore(snapshotSourceEventID: UUID)
    case debug
}
