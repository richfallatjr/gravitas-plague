import Foundation
import Combine
import RealityKit
import UIKit
import simd

@MainActor
final class PortalDoorController: ObservableObject {
    @Published private(set) var state: PortalDoorState = .notCreated
    @Published private(set) var placement: DoorPlacement?

    let root = Entity()
    private let doorRoot = Entity()
    private let portalWorldRoot = Entity()
    private let handleRoot = Entity()

    private var selectedWall: WallCandidate?
    private var contentProvider: PortalContentProvider =
        HDRIDomePortalContentProvider(atmosphere: .night)

    private var doorFrameEntity: Entity?
    private var portalPlaneEntity: ModelEntity?
    private var handleCollider: ModelEntity?

    init() {
        PortalDoorHandleComponent.registerComponent()

        root.name = "PortalDoorControllerRoot"
        doorRoot.name = "DoorRootEntity"
        portalWorldRoot.name = "PortalWorldRoot"
        handleRoot.name = "PortalDoorBottomHandleRoot"

        doorRoot.addChild(handleRoot)
        root.addChild(doorRoot)
        root.addChild(portalWorldRoot)
    }

    func setPortalContentProvider(
        provider: PortalContentProvider
    ) {
        self.contentProvider = provider
        placement?.contentProviderID = provider.providerID
        print("[PortalDoor] content provider set \(provider.providerID)")
    }

    private func resetDoorChildrenKeepingHandle() {
        doorRoot.children.removeAll()
        doorRoot.addChild(handleRoot)
        handleCollider = nil
    }

    func reloadPortalContent() async {
        guard state == .active ||
              state == .confirmed ||
              state == .adjusting else {
            return
        }

        portalWorldRoot.children.removeAll()
        portalWorldRoot.components.set(WorldComponent())

        let context: PortalContentContext
        if let placement {
            context = .forDoor(
                width: placement.width,
                height: placement.height
            )
        } else {
            context = .forDoor(
                width: 0.92,
                height: 2.0
            )
        }

        do {
            try await contentProvider.populatePortalWorld(
                portalWorld: portalWorldRoot,
                context: context
            )

            print(
                """
                [PortalDoor] portal content reloaded
                  provider: \(contentProvider.providerID)
                """
            )
        } catch {
            print(
                """
                [PortalDoor] ERROR portal content reload failed
                  provider: \(contentProvider.providerID)
                  error: \(error.localizedDescription)
                """
            )
        }
    }

    func createDoorPreview(
        onWall wall: WallCandidate,
        wallManager: WallPlaneManager
    ) {
        selectedWall = wall

        var p = DoorPlacement.defaultForWall(wall)
        p.confirmed = false
        p.contentProviderID = contentProvider.providerID
        p.floorLocked = true
        p = wallManager.resolveFloorLockedPlacementOrFallback(p)
        placement = p

        resetDoorChildrenKeepingHandle()

        let frame = makeDoorFrame(
            width: p.width,
            height: p.height,
            preview: true
        )

        doorRoot.addChild(frame)
        doorFrameEntity = frame

        applyTransformFromPlacement(
            wallManager: wallManager
        )
        rebuildBottomHandle()

        state = .preview

        print(
            """
            [PortalDoor] preview created wall=\(wall.id)
              localX: \(p.localX)
              localY: \(p.localY)
              width: \(p.width)
              height: \(p.height)
            """
        )
    }

    func activatePortalDoor(
        wallManager: WallPlaneManager
    ) async -> Bool {
        guard var p = placement else {
            print("[PortalDoor] activate failed: no placement")
            return false
        }

        guard let wall = selectedWall else {
            print("[PortalDoor] activate failed: no wall")
            return false
        }

        p.confirmed = true
        p.contentProviderID = contentProvider.providerID
        p.floorLocked = true
        p = wallManager.resolveFloorLockedPlacementOrFallback(p)
        placement = p

        resetDoorChildrenKeepingHandle()
        portalWorldRoot.children.removeAll()

        portalWorldRoot.components.set(WorldComponent())

        let context = PortalContentContext.forDoor(
            width: p.width,
            height: p.height
        )

        do {
            try await contentProvider.populatePortalWorld(
                portalWorld: portalWorldRoot,
                context: context
            )
        } catch {
            print(
                """
                [PortalDoor] ERROR portal HDRI content failed
                  provider: \(contentProvider.providerID)
                  error: \(error.localizedDescription)
                """
            )
            return false
        }

        let frame = makeDoorFrame(
            width: p.width,
            height: p.height,
            preview: false
        )

        let portalPlane = makePortalPlane(
            width: p.width * 0.82,
            height: p.height * 0.84,
            targetWorld: portalWorldRoot
        )

        portalPlane.position = SIMD3<Float>(
            0,
            0,
            -0.006
        )

        doorRoot.addChild(frame)
        doorRoot.addChild(portalPlane)

        doorFrameEntity = frame
        portalPlaneEntity = portalPlane

        applyTransformFromPlacement(
            wallManager: wallManager
        )
        rebuildBottomHandle()

        state = .active
        logFloorAnchorProof(
            placement: p,
            wall: wall
        )

        print(
            """
            [PortalDoor] portal activated
              wall: \(wall.id)
              localX: \(p.localX)
              localY: \(p.localY)
              provider: \(contentProvider.providerID)
            """
        )

        return true
    }

    func setDoorLocalPosition(
        x: Float,
        y: Float,
        wallManager: WallPlaneManager
    ) {
        guard var p = placement,
              let wall = selectedWall else {
            return
        }

        p.localX = x

        if p.floorLocked {
            print(
                """
                [PortalDoor] vertical drag ignored because portal is floor-locked
                  requestedY: \(y)
                  currentY: \(p.localY)
                """
            )
        } else {
            p.localY = y
        }

        p = wallManager.resolveFloorLockedPlacementOrFallback(p)
        p = wallManager.clampPlacement(p, on: wall)

        placement = p

        applyTransformFromPlacement(
            wallManager: wallManager
        )
        rebuildBottomHandle()

        print(
            """
            [PortalDoor] adjustment updated localX=\(String(format: "%.3f", p.localX)) localY=\(String(format: "%.3f", p.localY))
              wall: \(wall.id)
            """
        )
    }

    func slideDoor(
        toWallLocal local: SIMD2<Float>,
        wallManager: WallPlaneManager
    ) {
        setDoorLocalPosition(
            x: local.x,
            y: local.y,
            wallManager: wallManager
        )
    }

    func enterAdjustment() {
        guard state == .preview ||
              state == .active ||
              state == .confirmed else {
            return
        }

        state = .adjusting
        print("[PortalDoor] adjustment started")
    }

    func confirmPlacement() {
        guard var p = placement else {
            return
        }

        p.confirmed = true
        placement = p
        state = .confirmed

        print(
            """
            [PortalDoor] placement confirmed wall=\(p.wallID)
              localX: \(p.localX)
              localY: \(p.localY)
              width: \(p.width)
              height: \(p.height)
              provider: \(p.contentProviderID)
            """
        )
    }

    func updateForWallRefinement(
        wall: WallCandidate,
        wallManager: WallPlaneManager
    ) {
        guard placement?.wallID == wall.id else {
            return
        }

        selectedWall = wall

        applyTransformFromPlacement(
            wallManager: wallManager
        )
        rebuildBottomHandle()

        print(
            """
            [PortalDoor] wall refinement applied
              wallID: \(wall.id)
              keptLocalPlacement: true
              source: wall_anchor_update_not_head
            """
        )
    }

    private func applyTransformFromPlacement(
        wallManager: WallPlaneManager
    ) {
        guard let placement else {
            return
        }

        let resolvedPlacement = wallManager.resolveFloorLockedPlacementOrFallback(
            placement
        )
        self.placement = resolvedPlacement

        guard
              let matrix = wallManager.convertWallLocalToWorldTransform(
                placement: resolvedPlacement
              ) else {
            return
        }

        doorRoot.setTransformMatrix(
            matrix,
            relativeTo: nil
        )

        if let wall = wallManager.wallCandidates[resolvedPlacement.wallID] {
            let doorNormal = normalizeSafe(
                SIMD3<Float>(
                    matrix.columns.2.x,
                    matrix.columns.2.y,
                    matrix.columns.2.z
                ),
                fallback: wall.normal
            )

            let normalDot = simd_dot(
                doorNormal,
                wall.normal
            )

            if normalDot < 0.98 {
                print(
                    """
                    [PortalDoor] ERROR door normal not aligned to wall normal
                      dot: \(normalDot)
                      doorNormal: \(doorNormal)
                      wallNormal: \(wall.normal)
                    """
                )
            }
        }
    }

    private func logFloorAnchorProof(
        placement: DoorPlacement,
        wall: WallCandidate
    ) {
        let bottomWorld =
            wall.center +
            wall.right * placement.localX +
            wall.up * (placement.localY - placement.height * 0.5)

        let difference = placement.floorWorldY.map {
            bottomWorld.y - $0
        } ?? 0
        let floorWorldYDescription = placement.floorWorldY.map { value in
            "\(value)"
        } ?? "nil"

        print(
            """
            [PortalDoor] floor anchor proof
              floorLocked: \(placement.floorLocked)
              bottomWorldY: \(bottomWorld.y)
              floorWorldY: \(floorWorldYDescription)
              difference: \(difference)
            """
        )
    }

    @MainActor
    func rebuildBottomHandle() {
        handleRoot.children.removeAll()

        guard let placement else {
            return
        }

        let handleWidth = max(0.36, placement.width * 0.62)
        let handleHeight: Float = 0.045
        let handleDepth: Float = 0.028
        let handleY = -placement.height * 0.5 - 0.115
        let handleZ: Float = 0.055

        handleRoot.position = SIMD3<Float>(
            0,
            handleY,
            handleZ
        )

        let material = SimpleMaterial(
            color: UIColor.white.withAlphaComponent(0.94),
            roughness: 0.22,
            isMetallic: false
        )

        let collider = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(
                    handleWidth,
                    handleHeight,
                    handleDepth
                )
            ),
            materials: [material]
        )

        collider.name = "PortalDoorBottomWhitePlacementBar"
        collider.components.set(
            PortalDoorHandleComponent(
                doorID: placement.wallID.uuidString
            )
        )
        collider.components.set(InputTargetComponent())
        collider.generateCollisionShapes(recursive: true)

        handleRoot.addChild(collider)
        handleCollider = collider

        print(
            """
            [PortalDoor] bottom placement handle rebuilt
              width: \(handleWidth)
              height: \(handleHeight)
              localPosition: \(handleRoot.position)
              inputTarget: true
              collision: true
            """
        )
    }

    private func makeDoorFrame(
        width: Float,
        height: Float,
        preview: Bool
    ) -> Entity {
        let root = Entity()
        root.name = preview ? "DoorFramePreviewEntity" : "DoorFrameEntity"

        let trim: Float = 0.075
        let depth: Float = 0.055

        let color = preview
            ? UIColor.systemCyan.withAlphaComponent(0.42)
            : UIColor(
                red: 0.20,
                green: 0.08,
                blue: 0.04,
                alpha: 1.0
            )

        let material = SimpleMaterial(
            color: color,
            roughness: 0.65,
            isMetallic: false
        )

        func box(
            name: String,
            size: SIMD3<Float>,
            position: SIMD3<Float>
        ) -> ModelEntity {
            let e = ModelEntity(
                mesh: .generateBox(size: size),
                materials: [material]
            )
            e.name = name
            e.position = position
            return e
        }

        let left = box(
            name: "DoorFrame_LeftTrim",
            size: SIMD3<Float>(trim, height, depth),
            position: SIMD3<Float>(-width * 0.5, 0, 0)
        )

        let right = box(
            name: "DoorFrame_RightTrim",
            size: SIMD3<Float>(trim, height, depth),
            position: SIMD3<Float>(width * 0.5, 0, 0)
        )

        let top = box(
            name: "DoorFrame_TopTrim",
            size: SIMD3<Float>(width + trim, trim, depth),
            position: SIMD3<Float>(0, height * 0.5, 0)
        )

        let bottom = box(
            name: "DoorFrame_Threshold",
            size: SIMD3<Float>(width + trim, trim * 0.6, depth),
            position: SIMD3<Float>(0, -height * 0.5, 0)
        )

        root.addChild(left)
        root.addChild(right)
        root.addChild(top)
        root.addChild(bottom)

        return root
    }

    private func makePortalPlane(
        width: Float,
        height: Float,
        targetWorld: Entity
    ) -> ModelEntity {
        let material = PortalMaterial()

        let portal = ModelEntity(
            mesh: .generatePlane(
                width: width,
                height: height
            ),
            materials: [material]
        )

        portal.name = "PortalPlaneEntity"

        portal.components.set(
            PortalComponent(
                target: targetWorld
            )
        )

        portal.components.set(InputTargetComponent())
        portal.generateCollisionShapes(recursive: true)

        return portal
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
