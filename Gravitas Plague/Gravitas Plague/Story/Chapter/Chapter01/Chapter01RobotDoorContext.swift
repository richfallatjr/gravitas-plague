import RealityKit

struct Chapter01RobotDoorContext {
    let doorRoot: Entity
    let portalWorldRoot: Entity
    let portalPlane: Entity
    let robotExteriorStart: Entity
    let robotExteriorMid: Entity
    let robotDoorThreshold: Entity
    let doorAudioEmitter: Entity

    init(battleContext: TuringStoryDoorBattlePortalContext) {
        doorRoot = battleContext.doorRoot
        portalWorldRoot = battleContext.portalWorldRoot
        portalPlane = battleContext.portalPlane
        robotExteriorStart = battleContext.zombieA1
        robotExteriorMid = battleContext.zombieA2
        robotDoorThreshold = battleContext.zombieA3
        doorAudioEmitter = battleContext.doorAudioEmitter

        print("""
        [Chapter01RobotDoor] authored aliases resolved
          robotExteriorStartSource: \(battleContext.zombieA1.name)
          robotExteriorMidSource: \(battleContext.zombieA2.name)
          robotDoorThresholdSource: \(battleContext.zombieA3.name)
          startWorld: \(robotExteriorStart.transformMatrix(relativeTo: nil))
          midWorld: \(robotExteriorMid.transformMatrix(relativeTo: nil))
          thresholdWorld: \(robotDoorThreshold.transformMatrix(relativeTo: nil))
        """)
    }
}

extension TuringStoryDoorBundleController {
    func chapter01RobotDoorContext() throws -> Chapter01RobotDoorContext {
        Chapter01RobotDoorContext(battleContext: try battlePortalContext())
    }
}
