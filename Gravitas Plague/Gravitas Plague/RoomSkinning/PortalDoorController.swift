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

    private var selectedWall: WallCandidate?
    private var contentProvider: PortalContentProvider =
        HDRIDomePortalContentProvider(atmosphere: .night)

    private var doorFrameEntity: Entity?
    private var portalPlaneEntity: ModelEntity?

    init() {
        root.name = "PortalDoorControllerRoot"
        doorRoot.name = "DoorRootEntity"
        portalWorldRoot.name = "PortalWorldRoot"

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

    func reloadPortalContent() async {
        guard state == .active ||
              state == .confirmed ||
              state == .adjusting else {
            return
        }

        portalWorldRoot.children.removeAll()
        portalWorldRoot.components.set(WorldComponent())

        do {
            try await contentProvider.populatePortalWorld(
                portalWorld: portalWorldRoot
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
        placement = wallManager.clampPlacement(p, on: wall)

        doorRoot.children.removeAll()

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
        placement = p

        doorRoot.children.removeAll()
        portalWorldRoot.children.removeAll()

        portalWorldRoot.components.set(WorldComponent())

        do {
            try await contentProvider.populatePortalWorld(
                portalWorld: portalWorldRoot
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

        state = .active

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
        p.localY = y

        p = wallManager.clampPlacement(
            p,
            on: wall
        )

        placement = p

        applyTransformFromPlacement(
            wallManager: wallManager
        )

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
        guard state == .active || state == .confirmed else {
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
    }

    private func applyTransformFromPlacement(
        wallManager: WallPlaneManager
    ) {
        guard let placement,
              let matrix = wallManager.convertWallLocalToWorldTransform(
                placement: placement
              ) else {
            return
        }

        doorRoot.setTransformMatrix(
            matrix,
            relativeTo: nil
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
