import Foundation
import RealityKit

enum TuringStoryDoorBattleState: String, Sendable {
    case closed
    case opening
    case open
    case closing
}

struct TuringStoryDoorBattlePortalContext {
    let doorRoot: Entity
    let portalWorldRoot: Entity
    let portalPlane: Entity
    let zombieA1: Entity
    let zombieA2: Entity
    let zombieA3: Entity
    let doorAudioEmitter: Entity
}

@MainActor
protocol TuringStoryDoorBattleControlling: AnyObject {
    var battleDoorState: TuringStoryDoorBattleState { get }
    func setBattleInteractionLocked(
        _ locked: Bool,
        ownerID: UUID,
        reason: String
    )
    func openForBattle(ownerID: UUID, reason: String) async throws
    func battlePortalContext() throws -> TuringStoryDoorBattlePortalContext
}

extension TuringStoryDoorBundleController: TuringStoryDoorBattleControlling {}
