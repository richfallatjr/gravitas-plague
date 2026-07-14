import Foundation
import RealityKit
import simd

@MainActor
final class StoryPortalEnemyRenderMirrorAdapter {
    let id: UUID

    private let source: JockRetargetTestController
    private let portalWorldRoot: Entity
    private let portalPlane: HordePortalPlaneDescriptor
    private let mirror: HordePortalSkinnedRenderMirror
    private let sourceIBLEntity = Entity()
    private weak var boundIBLEntity: Entity?
    private var didLogMissingIBL = false
    private(set) var sourceRevealed = false
    private(set) var exited = false

    init(
        source: JockRetargetTestController,
        portalWorldRoot: Entity,
        portalPlaneEntity: Entity
    ) throws {
        self.source = source
        self.portalWorldRoot = portalWorldRoot
        self.portalPlane = Self.makePlaneDescriptor(portalPlaneEntity)
        self.mirror = try HordePortalSkinnedRenderMirror(
            source: source,
            portalID: UUID(),
            portalWorldRoot: portalWorldRoot,
            portalPlane: portalPlane,
            bodySizeMeters: source.portalMirrorBodySizeMeters()
        )
        self.id = mirror.id
        sourceIBLEntity.name = "Battle01GrandmaSourceIBL"
        mirror.syncVisibleDuringIngress()
        refreshPortalLightingIfNeeded()
    }

    var rootEntity: Entity { mirror.rootEntity }

    func signedRoomDistance() -> Float {
        portalPlane.signedRoomSideDistance(
            worldPosition: source.currentSimplifiedBodyCenterWorld()
        )
    }

    func sync(
        revealThreshold: Float,
        exitThreshold: Float
    ) {
        refreshPortalLightingIfNeeded()
        guard !exited else { return }

        let worldPosition = source.rootEntity.position(relativeTo: nil)
        let worldOrientation = source.rootEntity.orientation(relativeTo: nil)
        mirror.syncFromSource(
            worldPosition: worldPosition,
            worldOrientation: worldOrientation,
            portalWorldRoot: portalWorldRoot
        )
        mirror.updateAfterSourceAnimationApplied(
            sourceBodyCenterWorld: source.currentSimplifiedBodyCenterWorld()
        )

        let depth = signedRoomDistance()
        if !sourceRevealed, depth >= revealThreshold {
            sourceRevealed = true
            source.rootEntity.isEnabled = true
            print("[Battle01] portal reveal threshold crossed depth=\(depth)")
        }

        if depth >= exitThreshold {
            exited = true
            source.rootEntity.isEnabled = true
            mirror.cleanup(reason: "Battle01.portalExit")
            print("[Battle01] portal exit threshold crossed depth=\(depth)")
        }
    }

    func cleanup(reason: String) {
        exited = true
        mirror.cleanup(reason: reason)
        sourceIBLEntity.removeFromParent()
    }

    func refreshPortalLightingIfNeeded() {
        if !exited, mirror.rootEntity.parent == nil {
            portalWorldRoot.addChild(mirror.rootEntity)
            mirror.syncVisibleDuringIngress()
            print(
                "[Battle01Lighting] Grandma portal mirror restored after portal-world reload"
            )
        }

        guard let iblEntity = Self.firstIBLEntity(in: portalWorldRoot) else {
            if !didLogMissingIBL {
                didLogMissingIBL = true
                print(
                    "[Battle01Lighting] portal IBL unavailable; waiting for portal world population"
                )
            }
            return
        }

        didLogMissingIBL = false
        guard boundIBLEntity !== iblEntity else { return }
        guard let iblComponent = iblEntity.components[ImageBasedLightComponent.self] else {
            return
        }

        sourceIBLEntity.components.set(iblComponent)
        if sourceIBLEntity.parent == nil {
            source.rootEntity.parent?.addChild(sourceIBLEntity)
        }

        let sourceReceiverCount = Self.attachIBLReceiversRecursively(
            under: source.rootEntity,
            iblEntity: sourceIBLEntity
        )
        let mirrorReceiverCount = Self.attachIBLReceiversRecursively(
            under: mirror.rootEntity,
            iblEntity: iblEntity
        )
        let replacedPreviousIBL = boundIBLEntity != nil
        boundIBLEntity = iblEntity

        print(
            """
            [Battle01Lighting] Grandma bound to portal IBL
              iblEntity: \(iblEntity.name)
              sourceEnemyID: \(source.hordeBenchmarkID.uuidString)
              sourceReceiverCount: \(sourceReceiverCount)
              mirrorReceiverCount: \(mirrorReceiverCount)
              replacedPreviousIBL: \(replacedPreviousIBL)
              sourceIBLEntity: \(sourceIBLEntity.name)
              mirrorIBLEntity: \(iblEntity.name)
              sharedEnvironmentResource: true
              receiverWorlds: source_room,mirror_portal
            """
        )
    }

    func roomSideTarget(distance: Float, floorY: Float) -> SIMD3<Float> {
        var target = portalPlane.pointWorld + portalPlane.roomNormalWorld * distance
        target.y = floorY
        return target
    }

    private static func makePlaneDescriptor(_ portalPlaneEntity: Entity) -> HordePortalPlaneDescriptor {
        let point = portalPlaneEntity.convert(position: .zero, to: nil)
        let normalTarget = portalPlaneEntity.convert(
            position: HordePortalLocalAxes.outToRoom,
            to: nil
        )
        let raw = normalTarget - point
        let normal = simd_length(raw) > 0.001
            ? simd_normalize(raw)
            : HordePortalLocalAxes.outToRoom
        return HordePortalPlaneDescriptor(
            pointWorld: point,
            roomNormalWorld: normal
        )
    }

    private static func firstIBLEntity(
        in root: Entity
    ) -> Entity? {
        if root.components[ImageBasedLightComponent.self] != nil {
            return root
        }

        for child in root.children {
            if let found = firstIBLEntity(in: child) {
                return found
            }
        }

        return nil
    }

    @discardableResult
    private static func attachIBLReceiversRecursively(
        under root: Entity,
        iblEntity: Entity
    ) -> Int {
        root.components.set(
            ImageBasedLightReceiverComponent(
                imageBasedLight: iblEntity
            )
        )

        return root.children.reduce(1) { count, child in
            count + attachIBLReceiversRecursively(
                under: child,
                iblEntity: iblEntity
            )
        }
    }
}
