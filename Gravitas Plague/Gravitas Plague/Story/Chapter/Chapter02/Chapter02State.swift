import Foundation

enum Chapter02State: Sendable, Equatable {
    case idle
    case loadingWomanRuntime
    case missingPersonsReady
    case dadHamReady
    case bigMikeWalkieReady
    case dadPhotoReady
    case blackoutBroadcastReady
    case womanExitingWindow
    case womanBattle
    case postBattleHamReady
    case gravitasPSAReady
    case ending
    case complete
    case failed(String)
    case cancelled
}

enum Chapter02Error: LocalizedError {
    case stageNotEstablished
    case missingRun
    case staleEvent
    case missingEpisodeBoundaryOwner
    case unsupportedContinuationCheckpoint
    case womanRuntimeUnavailable(String)
    case invalidRuntimeTransfer(String)
    case unexpectedCompletion(String)

    var errorDescription: String? {
        switch self {
        case .stageNotEstablished:
            return "The established Story room is unavailable."
        case .missingRun:
            return "Chapter 2 has no active run."
        case .staleEvent:
            return "Chapter 2 received a stale runtime event."
        case .missingEpisodeBoundaryOwner:
            return "Chapter 2 has no episode-boundary owner."
        case .unsupportedContinuationCheckpoint:
            return "The saved Chapter 2 checkpoint cannot be continued."
        case .womanRuntimeUnavailable(let detail):
            return "Chapter 2 woman runtime is unavailable: \(detail)"
        case .invalidRuntimeTransfer(let detail):
            return "Chapter 2 woman runtime transfer failed: \(detail)"
        case .unexpectedCompletion(let id):
            return "Unexpected Chapter 2 completion: \(id)"
        }
    }
}

enum Chapter02WomanRuntimeTier: String, Sendable, Equatable {
    case windowPresentation
    case portalIntro
    case combat
    case released
}

enum Chapter02WindowWomanState: Sendable, Equatable {
    case unloaded
    case loading
    case atEntry
    case walkingEntryToCenter
    case turningLeftAtCenter
    case centeredIdle(cycle: Int)
    case presentingAttack(cycle: Int, index: Int, clipID: String)
    case exitRequested
    case turningRightToExit
    case walkingCenterToExit
    case stagedForDoor
    case transferredToPortalIntro
    case failed(String)
    case cancelled
}

struct Chapter02WomanWindowReadyEvent: Sendable {
    let chapterRunID: UUID
}

struct Chapter02WomanStagedForDoorEvent: Sendable {
    let chapterRunID: UUID
}

struct Chapter02WomanBattleReleasedEvent: Sendable {
    let chapterRunID: UUID
    let battleInstanceID: UUID
    let heavyRuntimeReleased: Bool
    let fullPortalReleased: Bool
}
