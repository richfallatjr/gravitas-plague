import ARKit
import Combine
import Foundation
import RealityKit
import simd

@MainActor
final class RoomSkinningCoordinator: ObservableObject {
    @Published private(set) var state: RoomSkinningState = .idle
    @Published private(set) var statusText: String = "Room skinning idle."

    let root = Entity()
    let wallManager = WallPlaneManager()
    let roomTrackingManager = RoomTrackingManager()
    let portalDoorController = PortalDoorController()

    var onStatusChanged: ((String) -> Void)?

    private weak var sceneRoot: Entity?

    private var monitorTask: Task<Void, Never>?

    private var lastPlayerPosition = SIMD3<Float>(0, 1.5, 0)
    private var lastPlayerForward = SIMD3<Float>(0, 0, -1)

    init() {
        root.name = "RoomSkinningRoot"
        root.addChild(portalDoorController.root)
    }

    func installIfNeeded(
        sceneRoot: Entity
    ) {
        self.sceneRoot = sceneRoot

        if root.parent == nil {
            sceneRoot.addChild(root)
        }

        print("[RoomSkinning] coordinator installed")
    }

    func handlePlaneAnchorUpdate(
        _ update: AnchorUpdate<PlaneAnchor>
    ) {
        wallManager.handlePlaneAnchorUpdate(update)
    }

    func updatePlayerPose(
        position: SIMD3<Float>,
        forward: SIMD3<Float>
    ) {
        lastPlayerPosition = position
        lastPlayerForward = normalizeSafe(
            forward,
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    func startRoomSkinning() {
        guard state == .idle || state == .failed else {
            print("[RoomSkinning] start ignored state=\(state.rawValue)")
            return
        }

        state = .scanning
        setStatus("Look around your room. Finding a wall...")
        wallManager.beginScanning()
        startCandidateMonitor()

        print("[RoomSkinning] scan started")
    }

    func cancelRoomSkinning() {
        monitorTask?.cancel()
        monitorTask = nil

        wallManager.stop()
        roomTrackingManager.stop()

        state = .idle
        setStatus("Room skinning cancelled.")

        print("[RoomSkinning] cancelled")
    }

    private func startCandidateMonitor() {
        monitorTask?.cancel()

        monitorTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)

                await MainActor.run {
                    self.evaluateBestWall()
                }
            }
        }
    }

    private func evaluateBestWall() {
        guard state == .scanning ||
              state == .wallCandidateAvailable ||
              state == .doorPreviewVisible else {
            return
        }

        guard let wall = wallManager.bestWallCandidate(
            relativeToPlayer: lastPlayerPosition,
            playerForward: lastPlayerForward
        ) else {
            state = .scanning
            setStatus("Scanning walls...")
            return
        }

        if state != .doorPreviewVisible {
            portalDoorController.createDoorPreview(
                onWall: wall,
                wallManager: wallManager
            )

            state = .doorPreviewVisible
            setStatus("Door preview ready. Confirm placement.")

            print("[RoomSkinning] door preview visible wall=\(wall.id)")
        } else {
            portalDoorController.updateForWallRefinement(
                wall: wall,
                wallManager: wallManager
            )
        }
    }

    func confirmRoomSkinning() {
        guard state == .doorPreviewVisible else {
            print("[RoomSkinning] confirm ignored state=\(state.rawValue)")
            return
        }

        Task { @MainActor in
            let activated = await portalDoorController.activatePortalDoor(
                wallManager: wallManager
            )

            guard activated else {
                state = .failed
                setStatus("Portal door failed to load HDRI content.")
                print("[RoomSkinning] room skinning confirm failed")
                return
            }

            state = .doorConfirmed
            setStatus("Portal door placed.")

            print("[RoomSkinning] room skinning confirmed")
        }
    }

    func updatePortalContentAtmosphere(
        _ atmosphere: PortalHDRIAtmosphere
    ) {
        let provider = HDRIDomePortalContentProvider(
            atmosphere: atmosphere
        )

        portalDoorController.setPortalContentProvider(
            provider: provider
        )

        if portalDoorController.state == .active ||
            portalDoorController.state == .confirmed ||
            portalDoorController.state == .adjusting {
            Task { @MainActor in
                await portalDoorController.reloadPortalContent()
            }
        }
    }

    func enterDoorAdjustment() {
        guard state == .doorConfirmed else {
            return
        }

        portalDoorController.enterAdjustment()

        state = .adjustingDoor
        setStatus("Adjusting door. Slide along wall.")

        print("[RoomSkinning] door adjustment entered")
    }

    func confirmDoorPlacement() {
        guard state == .adjustingDoor ||
              state == .doorConfirmed else {
            return
        }

        portalDoorController.confirmPlacement()

        state = .doorConfirmed
        setStatus("Door placement locked.")

        print("[RoomSkinning] door placement confirmed")
    }

    func slideDoorWithRay(
        _ ray: RoomSkinningRay
    ) {
        guard state == .adjustingDoor,
              let placement = portalDoorController.placement,
              let hit = wallManager.projectRayToWall(
                ray: ray,
                wallID: placement.wallID
              ),
              let local = wallManager.convertWorldPointToWallLocal(
                point: hit,
                wallID: placement.wallID
              ) else {
            return
        }

        portalDoorController.slideDoor(
            toWallLocal: local,
            wallManager: wallManager
        )
    }

    func isUnsafeCombatPositionNearConfirmedPortalWall(
        _ position: SIMD3<Float>
    ) -> Bool {
        guard let placement = portalDoorController.placement,
              placement.confirmed,
              let wall = wallManager.wallCandidates[placement.wallID] else {
            return false
        }

        let distanceToWall = abs(
            simd_dot(position - wall.center, wall.normal)
        )

        let wallLocalX = simd_dot(position - wall.center, wall.right)
        let wallLocalY = simd_dot(position - wall.center, wall.up)

        let nearDoor =
            abs(wallLocalX - placement.localX) < placement.width * 0.75 &&
            abs(wallLocalY - placement.localY) < placement.height * 0.65

        return distanceToWall < 0.35 && nearDoor
    }

    private func setStatus(
        _ status: String
    ) {
        statusText = status
        onStatusChanged?(status)
    }
}

private func normalizeSafe(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(v)
    guard length > 0.00001 else {
        return fallback
    }
    return v / length
}
