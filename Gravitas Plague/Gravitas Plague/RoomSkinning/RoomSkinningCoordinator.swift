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
    private var selectedWallID: UUID?

    private var lastPlayerPosition = SIMD3<Float>(0, 1.5, 0)
    private var lastPlayerForward = SIMD3<Float>(0, 0, -1)

    private struct DoorHandleDragState {
        var wallID: UUID
        var startDoorLocal: SIMD2<Float>
        var startHitLocal: SIMD2<Float>
    }

    private var activeDoorHandleDrag: DoorHandleDragState?

    var isDoorHandleDragActive: Bool {
        activeDoorHandleDrag != nil
    }

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
        wallManager.updateViewerPositionForWallSelection(position)
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
        selectedWallID = nil
        activeDoorHandleDrag = nil

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
        switch state {
        case .scanning, .wallCandidateAvailable:
            guard let wall = wallManager.bestWallCandidate(
                relativeToPlayer: lastPlayerPosition,
                playerForward: lastPlayerForward
            ) else {
                state = .scanning
                setStatus("Scanning walls...")
                return
            }

            selectedWallID = wall.id

            portalDoorController.createDoorPreview(
                onWall: wall,
                wallManager: wallManager
            )

            state = .doorPreviewVisible
            setStatus("Door preview ready. Grab the white handle to place.")

            print(
                """
                [RoomSkinning] selected wall frozen for door preview
                  wallID: \(wall.id)
                  source: best_wall_once_not_head_follow
                """
            )
            print("[RoomSkinning] door preview visible wall=\(wall.id)")

        case .doorPreviewVisible, .adjustingDoor, .doorConfirmed:
            guard let selectedWallID,
                  let wall = wallManager.wallCandidates[selectedWallID] else {
                return
            }

            portalDoorController.updateForWallRefinement(
                wall: wall,
                wallManager: wallManager
            )

        default:
            return
        }
    }

    func confirmRoomSkinning() {
        guard state == .doorPreviewVisible ||
              state == .adjustingDoor else {
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

    func beginDoorHandleDrag(
        worldPoint: SIMD3<Float>
    ) {
        guard let placement = portalDoorController.placement else {
            return
        }

        let projected = wallManager.projectWorldPointToWall(
            worldPoint,
            wallID: placement.wallID
        ) ?? worldPoint

        guard let hitLocal = wallManager.convertWorldPointToWallLocal(
            point: projected,
            wallID: placement.wallID
        ) else {
            return
        }

        activeDoorHandleDrag = DoorHandleDragState(
            wallID: placement.wallID,
            startDoorLocal: SIMD2<Float>(
                placement.localX,
                placement.localY
            ),
            startHitLocal: hitLocal
        )

        if state == .doorPreviewVisible {
            state = .adjustingDoor
            portalDoorController.enterAdjustment()
            setStatus("Adjusting door. Drag the white handle.")
        }

        print(
            """
            [PortalDoor] handle drag began
              wallID: \(placement.wallID)
              startDoorLocal: \(SIMD2<Float>(placement.localX, placement.localY))
              startHitLocal: \(hitLocal)
              inputSource: handle_gesture_not_head
            """
        )
    }

    func updateDoorHandleDrag(
        worldPoint: SIMD3<Float>
    ) {
        guard let drag = activeDoorHandleDrag else {
            return
        }

        let projected = wallManager.projectWorldPointToWall(
            worldPoint,
            wallID: drag.wallID
        ) ?? worldPoint

        guard let hitLocal = wallManager.convertWorldPointToWallLocal(
            point: projected,
            wallID: drag.wallID
        ) else {
            return
        }

        let delta = hitLocal - drag.startHitLocal
        let newLocal = drag.startDoorLocal + delta

        portalDoorController.setDoorLocalPosition(
            x: newLocal.x,
            y: newLocal.y,
            wallManager: wallManager
        )

        print(
            """
            [PortalDoor] handle drag updated
              wallID: \(drag.wallID)
              newLocal: \(newLocal)
              inputSource: handle_gesture_not_head
            """
        )
    }

    func endDoorHandleDrag(
        shouldConfirm: Bool = true
    ) {
        guard activeDoorHandleDrag != nil else {
            return
        }

        activeDoorHandleDrag = nil

        if shouldConfirm {
            if portalDoorController.placement?.confirmed == true {
                confirmDoorPlacement()
            } else {
                confirmRoomSkinning()
            }
        }

        print(
            """
            [PortalDoor] handle drag ended
              shouldConfirm: \(shouldConfirm)
              inputSource: handle_gesture_not_head
            """
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
