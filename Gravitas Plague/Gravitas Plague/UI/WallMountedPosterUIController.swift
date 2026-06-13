import Combine
import RealityKit
import UIKit
import simd

enum WallPosterPlacementState: String {
    case notPlaced
    case placed
    case locked
}

@MainActor
final class WallMountedPosterUIController: ObservableObject {
    private(set) var root = Entity()
    private var posterEntity: ModelEntity?
    private var buttonEntities: [Entity] = []

    private weak var wallManager: WallPlaneManager?
    private weak var hordePortalManager: HordePortalManager?

    private var currentPlacement: WallPosterPlacement?
    private var currentPosterSize: SIMD2<Float>?
    private var placementState: WallPosterPlacementState = .notPlaced
    private var lastAppliedPosition: SIMD3<Float>?

    var isPlaced: Bool {
        currentPlacement != nil
    }

    init() {
        WallPosterUIButtonComponent.registerComponent()
        WallPosterKillSwitchComponent.registerComponent()
        root.name = "WallMountedPosterUIRoot"
    }

    func installIfNeeded(
        sceneRoot: Entity,
        wallManager: WallPlaneManager,
        hordePortalManager: HordePortalManager?
    ) {
        self.wallManager = wallManager
        self.hordePortalManager = hordePortalManager

        if root.parent == nil {
            sceneRoot.addChild(root)
        }

        print("[WallPosterUI] installed")
    }

    @discardableResult
    func placeOnBestWall(
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>,
        force: Bool = false
    ) -> Bool {
        if !force,
           placementState == .placed || placementState == .locked {
            return false
        }

        guard let wallManager else {
            print("[WallPosterUI] ERROR no wallManager")
            return false
        }

        guard let placement = choosePlacement(
            wallManager: wallManager,
            playerPosition: playerPosition,
            playerForward: playerForward
        ) else {
            print("[WallPosterUI] no valid wall placement yet")
            return false
        }

        currentPlacement = placement
        placementState = .placed

        rebuildPosterIfNeeded(
            width: placement.width,
            height: placement.height
        )
        applyPlacement(placement)

        print(
            """
            [WallPosterUI] wall placement active
              wallID: \(placement.wallID)
              width: \(placement.width)
              height: \(placement.height)
              heightMeters: \(placement.height)
              localX: \(placement.localX)
              localY: \(placement.localY)
              depthOffset: \(placement.depthOffset)
            """
        )

        return true
    }

    func lockPlacement() {
        guard let currentPlacement else {
            return
        }

        placementState = .locked

        print(
            """
            [WallPosterUI] placement locked
              wallID: \(currentPlacement.wallID)
              localX: \(currentPlacement.localX)
              localY: \(currentPlacement.localY)
              snapsToHead: false
            """
        )
    }

    func refreshTransformForWallUpdate() {
        guard let placement = currentPlacement else {
            return
        }

        applyPlacement(placement)
    }

    func reset() {
        currentPlacement = nil
        currentPosterSize = nil
        placementState = .notPlaced
        lastAppliedPosition = nil
        posterEntity = nil
        buttonEntities.removeAll()
        root.isEnabled = false
    }

    private func choosePlacement(
        wallManager: WallPlaneManager,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> WallPosterPlacement? {
        let walls = wallManager.wallCandidates.values
            .filter {
                $0.width >= 0.30 &&
                $0.height >= 0.30
            }

        guard !walls.isEmpty else {
            return nil
        }

        let sorted = walls.sorted { lhs, rhs in
            let lhsDistance = simd_length(lhs.center - playerPosition)
            let rhsDistance = simd_length(rhs.center - playerPosition)
            let lhsAngle = angularCoverageScore(
                wall: lhs,
                playerPosition: playerPosition,
                playerForward: playerForward
            )
            let rhsAngle = angularCoverageScore(
                wall: rhs,
                playerPosition: playerPosition,
                playerForward: playerForward
            )

            if abs(lhsAngle - rhsAngle) > 0.1 {
                return lhsAngle > rhsAngle
            }

            return lhsDistance < rhsDistance
        }

        for wall in sorted {
            if let placement = bestSlot(
                on: wall,
                wallManager: wallManager
            ) {
                return placement
            }
        }

        return nil
    }

    private func angularCoverageScore(
        wall: WallCandidate,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> Float {
        let toWall = normalizeSafe(
            wall.center - playerPosition,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        return max(
            0,
            simd_dot(
                toWall,
                playerForward
            )
        )
    }

    private func bestSlot(
        on wall: WallCandidate,
        wallManager: WallPlaneManager
    ) -> WallPosterPlacement? {
        let size = WallPosterMetrics.posterSize(
            for: wall
        )
        let width = size.x
        let height = size.y
        let floorY = wallManager.bestFloorCandidate(near: wall)?.worldY
        let desiredWorldY: Float = floorY.map { $0 + 1.35 } ?? wall.center.y
        let desiredLocalY: Float

        if abs(wall.up.y) > 0.05 {
            desiredLocalY = (desiredWorldY - wall.center.y) / wall.up.y
        } else {
            desiredLocalY = 0
        }

        let maxX = max(
            0,
            wall.width * 0.5 - width * 0.5 - 0.06
        )
        let maxY = max(
            0,
            wall.height * 0.5 - height * 0.5 - 0.06
        )

        let candidateXs: [Float] = [
            0,
            -maxX * 0.65,
            maxX * 0.65,
            -maxX,
            maxX
        ]
        let candidateYs: [Float] = [
            min(max(desiredLocalY, -maxY), maxY),
            0,
            maxY * 0.4,
            -maxY * 0.4
        ]

        var best: (placement: WallPosterPlacement, score: Float)?

        for x in candidateXs {
            for y in candidateYs {
                let placement = WallPosterPlacement(
                    wallID: wall.id,
                    localX: x,
                    localY: y,
                    depthOffset: WallPosterMetrics.depthOffset,
                    width: width,
                    height: height
                )
                let score = clearanceScore(
                    placement: placement,
                    wall: wall
                )

                if best == nil ||
                   score > best!.score {
                    best = (
                        placement,
                        score
                    )
                }
            }
        }

        return best?.placement
    }

    private func clearanceScore(
        placement: WallPosterPlacement,
        wall: WallCandidate
    ) -> Float {
        var score: Float = 1.0

        if let hordePortalManager {
            let rect = SIMD4<Float>(
                placement.localX - placement.width * 0.5,
                placement.localY - placement.height * 0.5,
                placement.width,
                placement.height
            )

            for portalRect in hordePortalManager.occupiedWallRects(wallID: wall.id) {
                if rectsOverlap(
                    rect,
                    portalRect
                ) {
                    score -= 10.0

                    print(
                        """
                        [WallPosterUI] candidate rejected/penalized due to portal overlap
                          wallID: \(wall.id)
                          localX: \(placement.localX)
                          localY: \(placement.localY)
                        """
                    )
                }
            }
        }

        score += abs(placement.localX) * 0.05

        return score
    }

    private func rectsOverlap(
        _ a: SIMD4<Float>,
        _ b: SIMD4<Float>
    ) -> Bool {
        let ax0 = a.x
        let ay0 = a.y
        let ax1 = a.x + a.z
        let ay1 = a.y + a.w
        let bx0 = b.x
        let by0 = b.y
        let bx1 = b.x + b.z
        let by1 = b.y + b.w

        return ax0 < bx1 &&
            ax1 > bx0 &&
            ay0 < by1 &&
            ay1 > by0
    }
}

private extension WallMountedPosterUIController {
    func rebuildPosterIfNeeded(
        width: Float,
        height: Float
    ) {
        let newSize = SIMD2<Float>(
            width,
            height
        )

        if let currentPosterSize,
           simd_length(currentPosterSize - newSize) < 0.001,
           posterEntity != nil {
            root.isEnabled = true
            return
        }

        root.children.removeAll()
        buttonEntities.removeAll()
        posterEntity = nil
        currentPosterSize = newSize
        root.isEnabled = true

        let texture = try? TextureResource.load(
            named: "plague_menu_ui_mockup"
        )

        var material = PhysicallyBasedMaterial()

        if let texture {
            material.baseColor = .init(
                texture: .init(texture)
            )
        } else {
            material.baseColor = .init(
                tint: .darkGray
            )

            print("[WallPosterUI] ERROR missing plague_menu_ui_mockup texture")
        }

        material.roughness = .init(floatLiteral: 0.82)
        material.metallic = .init(floatLiteral: 0.0)

        let poster = ModelEntity(
            mesh: .generatePlane(
                width: width,
                height: height
            ),
            materials: [material]
        )

        poster.name = "WallMountedPosterUIPanel"
        poster.components.remove(InputTargetComponent.self)
        poster.components.remove(CollisionComponent.self)

        root.addChild(poster)
        posterEntity = poster

        addButtonHitTarget(
            rectPixels: WallPosterMetrics.hordeRectPixels,
            posterWidth: width,
            posterHeight: height,
            action: .horde,
            name: "WallPosterButton_Horde"
        )

        addButtonHitTarget(
            rectPixels: WallPosterMetrics.walkRectPixels,
            posterWidth: width,
            posterHeight: height,
            action: .walkLoop,
            name: "WallPosterButton_WalkLoop"
        )

        addKillSwitchDecorator(
            posterWidth: width,
            posterHeight: height
        )

        print(
            """
            [WallPosterUI] RealityKit poster panel created
              texture: plague_menu_ui_mockup
              widthMeters: \(width)
              heightMeters: \(height)
              maxHeightInches: 36
              physicallyBasedMaterial: true
            """
        )
    }

    func addKillSwitchDecorator(
        posterWidth: Float,
        posterHeight: Float
    ) {
        guard let texture = try? TextureResource.load(
            named: "kill_switch_x"
        ) else {
            print("[WallPosterUI] ERROR missing kill_switch_x.png")
            return
        }

        var material = UnlitMaterial()
        material.color = .init(
            tint: .white,
            texture: .init(texture)
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: 1.0)
        )

        let size = min(
            0.095,
            posterHeight * 0.105
        )
        let x = posterWidth * 0.5 - size * 0.65
        let y = -posterHeight * 0.5 - size * 0.90

        let killSwitch = ModelEntity(
            mesh: .generatePlane(
                width: size,
                height: size
            ),
            materials: [material]
        )

        killSwitch.name = "WallPosterKillSwitch_X"
        killSwitch.position = SIMD3<Float>(
            x,
            y,
            0.018
        )
        killSwitch.components.set(
            WallPosterKillSwitchComponent(
                id: "wall_poster_kill"
            )
        )
        killSwitch.components.set(InputTargetComponent())
        killSwitch.generateCollisionShapes(recursive: true)

        root.addChild(killSwitch)

        print(
            """
            [WallPosterUI] RealityKit kill switch decorator created
              texture: kill_switch_x.png
              size: \(size)
              position: \(killSwitch.position)
              underPoster: true
            """
        )
    }

    func addButtonHitTarget(
        rectPixels: SIMD4<Float>,
        posterWidth: Float,
        posterHeight: Float,
        action: WallPosterAction,
        name: String
    ) {
        let source = WallPosterMetrics.sourcePixelSize
        let rectX = rectPixels.x
        let rectY = rectPixels.y
        let rectW = rectPixels.z
        let rectH = rectPixels.w
        let centerPixelX = rectX + rectW * 0.5
        let centerPixelY = rectY + rectH * 0.5
        let localX = (centerPixelX / source.x - 0.5) * posterWidth
        let localY = (0.5 - centerPixelY / source.y) * posterHeight
        let width = rectW / source.x * posterWidth
        let height = rectH / source.y * posterHeight

        let hit = ModelEntity(
            mesh: .generatePlane(
                width: width,
                height: height
            ),
            materials: [makeInvisibleHitMaterial()]
        )

        hit.name = name
        hit.position = SIMD3<Float>(
            localX,
            localY,
            0.012
        )
        hit.components.set(
            WallPosterUIButtonComponent(
                actionRawValue: action.rawValue
            )
        )
        hit.components.set(InputTargetComponent())
        hit.generateCollisionShapes(recursive: true)

        root.addChild(hit)
        buttonEntities.append(hit)

        print(
            """
            [WallPosterUI] button hit target created
              name: \(name)
              action: \(action.rawValue)
              localX: \(localX)
              localY: \(localY)
              width: \(width)
              height: \(height)
              posterWidth: \(posterWidth)
              posterHeight: \(posterHeight)
            """
        )
    }

    func makeInvisibleHitMaterial() -> any RealityKit.Material {
        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor.white.withAlphaComponent(0.001)
        )
        material.blending = .transparent(opacity: 0.001)
        return material
    }

    func applyPlacement(
        _ placement: WallPosterPlacement
    ) {
        guard let wallManager,
              let wall = wallManager.wallCandidates[placement.wallID] else {
            return
        }

        let position =
            wall.center +
            wall.right * placement.localX +
            wall.up * placement.localY +
            wall.normal * placement.depthOffset

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(wall.right.x, wall.right.y, wall.right.z, 0)
        matrix.columns.1 = SIMD4<Float>(wall.up.x, wall.up.y, wall.up.z, 0)
        matrix.columns.2 = SIMD4<Float>(wall.normal.x, wall.normal.y, wall.normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        root.setTransformMatrix(
            matrix,
            relativeTo: nil
        )

        let shouldLog =
            lastAppliedPosition.map {
                simd_length(position - $0) > 0.01
            } ?? true

        lastAppliedPosition = position

        if shouldLog {
            print(
                """
                [WallPosterUI] wall transform applied
                  wallID: \(placement.wallID)
                  position: \(position)
                  basis: wall_basis
                """
            )
        }
    }
}

private func normalizeSafe(
    _ vector: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length > 0.0001 else {
        return fallback
    }

    return vector / length
}
