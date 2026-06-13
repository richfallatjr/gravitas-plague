import Combine
import RealityKit
import UIKit
import simd

@MainActor
final class WallMountedPosterUIController: ObservableObject {
    private(set) var root = Entity()
    private var posterEntity: ModelEntity?
    private var buttonEntities: [Entity] = []

    private weak var wallManager: WallPlaneManager?
    private weak var hordePortalManager: HordePortalManager?

    private var currentPlacement: WallPosterPlacement?

    var isPlaced: Bool {
        currentPlacement != nil
    }

    init() {
        WallPosterUIButtonComponent.registerComponent()
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
        playerForward: SIMD3<Float>
    ) -> Bool {
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

        rebuildPosterIfNeeded()
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

    func refreshTransformForWallUpdate() {
        guard let placement = currentPlacement else {
            return
        }

        applyPlacement(placement)
    }

    func reset() {
        currentPlacement = nil
        root.isEnabled = false
    }

    private func choosePlacement(
        wallManager: WallPlaneManager,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> WallPosterPlacement? {
        let walls = wallManager.wallCandidates.values
            .filter {
                $0.width >= WallPosterMetrics.posterWidth + 0.1 &&
                $0.height >= WallPosterMetrics.posterHeight + 0.1
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
        let width = WallPosterMetrics.posterWidth
        let height = WallPosterMetrics.posterHeight
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
    func rebuildPosterIfNeeded() {
        guard posterEntity == nil else {
            root.isEnabled = true
            return
        }

        root.children.removeAll()
        buttonEntities.removeAll()
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
                width: WallPosterMetrics.posterWidth,
                height: WallPosterMetrics.posterHeight
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
            action: .horde,
            name: "WallPosterButton_Horde"
        )

        addButtonHitTarget(
            rectPixels: WallPosterMetrics.walkRectPixels,
            action: .walkLoop,
            name: "WallPosterButton_WalkLoop"
        )

        print(
            """
            [WallPosterUI] RealityKit poster panel created
              texture: plague_menu_ui_mockup
              widthMeters: \(WallPosterMetrics.posterWidth)
              heightMeters: \(WallPosterMetrics.posterHeight)
              maxHeightInches: 24
              physicallyBasedMaterial: true
            """
        )
    }

    func addButtonHitTarget(
        rectPixels: SIMD4<Float>,
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
        let localX = (centerPixelX / source.x - 0.5) * WallPosterMetrics.posterWidth
        let localY = (0.5 - centerPixelY / source.y) * WallPosterMetrics.posterHeight
        let width = rectW / source.x * WallPosterMetrics.posterWidth
        let height = rectH / source.y * WallPosterMetrics.posterHeight

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
