import Foundation
import RealityKit

@MainActor
final class Chapter03LightTunnelSceneBundle {
    let root: Entity
    let portalTravelRoot: Entity
    let portalWorld: Entity
    let portalDome: ModelEntity
    let iblEntity: Entity
    let environment: EnvironmentResource
    let angel: Chapter03AngelPortalEntity
    let runtimePortalAperture: ModelEntity?
    let portalGeometry: Chapter03CircularPortalGeometry
    let definition: Chapter03LightTunnelVisualDefinition

    init(
        root: Entity,
        portalTravelRoot: Entity,
        portalWorld: Entity,
        portalDome: ModelEntity,
        iblEntity: Entity,
        environment: EnvironmentResource,
        angel: Chapter03AngelPortalEntity,
        runtimePortalAperture: ModelEntity?,
        portalGeometry: Chapter03CircularPortalGeometry,
        definition: Chapter03LightTunnelVisualDefinition
    ) {
        self.root = root
        self.portalTravelRoot = portalTravelRoot
        self.portalWorld = portalWorld
        self.portalDome = portalDome
        self.iblEntity = iblEntity
        self.environment = environment
        self.angel = angel
        self.runtimePortalAperture = runtimePortalAperture
        self.portalGeometry = portalGeometry
        self.definition = definition
    }

    func release(reason: String) {
        angel.release(reason: reason)
        PlagueNativeBloomInstaller.removeBloom(from: portalWorld)
        root.removeFromParent()
    }
}
