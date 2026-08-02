import Foundation
import RealityKit

@MainActor
struct Chapter01RobotRuntime {
    let identity: BattleEnemyRuntimeIdentity
    let controller: JockRetargetTestController
    let roomRoot: Entity
    let mirror: StoryPortalEnemyRenderMirrorAdapter
    let speechEmitter: Entity
    let externalAudioAttachment: (any Chapter01RobotAudioAttachment)?
}
