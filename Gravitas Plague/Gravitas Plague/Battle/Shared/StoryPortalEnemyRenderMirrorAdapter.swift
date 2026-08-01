import Foundation
import RealityKit
import simd

enum StoryPortalTransitionDirection: String, Sendable, Equatable {
    case portalToRoom
    case roomToPortal
}

enum StoryPortalMirrorPhase: String, Sendable, Equatable {
    case exteriorOnly
    case overlap
    case roomOnly
    case released
}

struct StoryPortalMirrorThresholds: Sendable, Equatable {
    let sourceRevealDistance: Float
    let overlapEndDistance: Float
    let sourceHideDistance: Float
    let exteriorReleaseDistance: Float
}

@MainActor
final class StoryPortalEnemyRenderMirrorAdapter {
    private(set) var id: UUID

    private let source: JockRetargetTestController
    private let portalWorldRoot: Entity
    private let portalPlane: HordePortalPlaneDescriptor
    private var mirror: HordePortalSkinnedRenderMirror?
    private weak var boundIBLEntity: Entity?
    private var didLogMissingIBL = false
    private(set) var sourceRevealed = false
    private(set) var exited = false
    private(set) var direction: StoryPortalTransitionDirection
    private(set) var phase: StoryPortalMirrorPhase

    init(
        source: JockRetargetTestController,
        portalWorldRoot: Entity,
        portalPlaneEntity: Entity,
        direction: StoryPortalTransitionDirection = .portalToRoom
    ) throws {
        self.source = source
        self.portalWorldRoot = portalWorldRoot
        self.portalPlane = Self.makePlaneDescriptor(portalPlaneEntity)
        self.direction = direction
        self.phase = direction == .portalToRoom ? .exteriorOnly : .roomOnly
        let removedSourceReceiverCount = Self.removeIBLReceiversRecursively(
            under: source.rootEntity
        )
        let mirror = try HordePortalSkinnedRenderMirror(
            source: source,
            portalID: UUID(),
            portalWorldRoot: portalWorldRoot,
            portalPlane: portalPlane,
            bodySizeMeters: source.portalMirrorBodySizeMeters()
        )
        self.mirror = mirror
        self.id = mirror.id
        mirror.syncVisibleDuringIngress()
        print(
            "[StoryPortalLighting] room-side source portal receivers cleared count=\(removedSourceReceiverCount) lighting=automatic_passthrough"
        )
        refreshPortalLightingIfNeeded()
    }

    func signedRoomDistance() -> Float {
        portalPlane.signedRoomSideDistance(
            worldPosition: source.currentSimplifiedBodyCenterWorld()
        )
    }

    func sync(
        revealThreshold: Float,
        exitThreshold: Float
    ) {
        guard direction == .portalToRoom else {
            assertionFailure("Ingress sync used during room-to-portal transition.")
            return
        }
        refreshPortalLightingIfNeeded()
        guard !exited,
              let mirror else { return }

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
            phase = .overlap
            print("[Battle01] portal reveal threshold crossed depth=\(depth)")
        }

        if depth >= exitThreshold {
            source.rootEntity.isEnabled = true
            phase = .roomOnly
            cleanup(reason: "Battle01.portalExit")
            print("[Battle01] portal exit threshold crossed depth=\(depth)")
        }
    }

    func prepareForRoomToPortalExit() throws {
        guard mirror == nil else {
            direction = .roomToPortal
            phase = .overlap
            exited = false
            source.rootEntity.isEnabled = true
            return
        }
        let next = try HordePortalSkinnedRenderMirror(
            source: source,
            portalID: UUID(),
            portalWorldRoot: portalWorldRoot,
            portalPlane: portalPlane,
            bodySizeMeters: source.portalMirrorBodySizeMeters()
        )
        mirror = next
        id = next.id
        direction = .roomToPortal
        phase = .overlap
        exited = false
        sourceRevealed = true
        source.rootEntity.isEnabled = true
        next.syncVisibleDuringIngress()
        refreshPortalLightingIfNeeded()
        print("[StoryPortalMirror] reverse transition prepared mirrorID=\(id.uuidString)")
    }

    func syncRoomToPortal(
        sourceHideThreshold: Float,
        exteriorReleaseThreshold: Float
    ) {
        guard direction == .roomToPortal,
              !exited,
              let mirror else { return }
        refreshPortalLightingIfNeeded()
        mirror.syncFromSource(
            worldPosition: source.rootEntity.position(relativeTo: nil),
            worldOrientation: source.rootEntity.orientation(relativeTo: nil),
            portalWorldRoot: portalWorldRoot
        )
        mirror.updateAfterSourceAnimationApplied(
            sourceBodyCenterWorld: source.currentSimplifiedBodyCenterWorld()
        )

        let depth = signedRoomDistance()
        if depth <= sourceHideThreshold, source.rootEntity.isEnabled {
            source.rootEntity.isEnabled = false
            phase = .exteriorOnly
            print("[StoryPortalMirror] room source hidden during exit depth=\(depth)")
        }
        if depth <= exteriorReleaseThreshold {
            source.rootEntity.isEnabled = false
            cleanup(reason: "Chapter01Robot.portalExteriorReached")
            print("[StoryPortalMirror] exterior release threshold crossed depth=\(depth)")
        }
    }

    func cleanup(reason: String) {
        guard let mirror else {
            exited = true
            phase = .released
            return
        }
        exited = true
        phase = .released
        mirror.cleanup(reason: reason)
        self.mirror = nil
        boundIBLEntity = nil
        TuringMemoryBudgetProbe.log(
            label: "afterBattle01PortalMirrorReleased"
        )
        print("""
        [Battle01Memory] portal mirror ownership released
          mirrorID: \(id.uuidString)
          reason: \(reason)
          mirrorRetainedByAdapter: false
          authoritativeEnemyRetained: true
        """)
    }

    func removeAndRelease(reason: String) {
        cleanup(reason: reason)
    }

    func refreshPortalLightingIfNeeded() {
        guard !exited,
              let mirror else { return }

        if mirror.rootEntity.parent == nil {
            portalWorldRoot.addChild(mirror.rootEntity)
            mirror.syncVisibleDuringIngress()
            print(
                "[StoryPortalLighting] portal mirror restored after portal-world reload"
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
        guard iblEntity.components[ImageBasedLightComponent.self] != nil else {
            return
        }

        let mirrorReceiverCount = Self.attachIBLReceiversRecursively(
            under: mirror.rootEntity,
            iblEntity: iblEntity
        )
        let replacedPreviousIBL = boundIBLEntity != nil
        boundIBLEntity = iblEntity

        print(
            """
            [StoryPortalLighting] portal mirror bound to portal IBL
              iblEntity: \(iblEntity.name)
              sourceEnemyID: \(source.hordeBenchmarkID.uuidString)
              sourceReceiverCount: 0
              mirrorReceiverCount: \(mirrorReceiverCount)
              replacedPreviousIBL: \(replacedPreviousIBL)
              mirrorIBLEntity: \(iblEntity.name)
              sourceLighting: automatic_passthrough
              mirrorLighting: portal_dome_ibl
              receiverWorlds: mirror_portal_only
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

    @discardableResult
    private static func removeIBLReceiversRecursively(
        under root: Entity
    ) -> Int {
        var removedCount = 0
        if root.components[ImageBasedLightReceiverComponent.self] != nil {
            root.components.remove(ImageBasedLightReceiverComponent.self)
            removedCount = 1
        }

        return root.children.reduce(removedCount) { count, child in
            count + removeIBLReceiversRecursively(under: child)
        }
    }
}
