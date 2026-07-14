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
        mirror.syncVisibleDuringIngress()
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
}
