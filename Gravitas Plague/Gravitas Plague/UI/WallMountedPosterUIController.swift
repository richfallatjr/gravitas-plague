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
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    private var currentPlacement: WallPosterPlacement?
    private var currentPosterSize: SIMD2<Float>?
    private var placementState: WallPosterPlacementState = .notPlaced
    private var lastAppliedPosition: SIMD3<Float>?
    private let posterOccupancyID = UUID()
    private(set) var hasRegisteredOccupancy = false

    var isPlaced: Bool {
        currentPlacement != nil
    }

    init() {
        WallPosterUIButtonComponent.registerComponent()
        WallPosterKillSwitchComponent.registerComponent()
        WallPosterLeaderboardButtonComponent.registerComponent()
        root.name = "WallMountedPosterUIRoot"
    }

    func installIfNeeded(
        sceneRoot: Entity,
        wallManager: WallPlaneManager,
        hordePortalManager: HordePortalManager?,
        occupancyRegistry: WallPropOccupancyRegistry
    ) {
        self.wallManager = wallManager
        self.hordePortalManager = hordePortalManager
        self.occupancyRegistry = occupancyRegistry

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
        registerPosterOccupancy(
            placement: placement
        )

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
        occupancyRegistry?.unregister(
            id: posterOccupancyID
        )

        currentPlacement = nil
        currentPosterSize = nil
        placementState = .notPlaced
        lastAppliedPosition = nil
        hasRegisteredOccupancy = false
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
        let desiredWorldY: Float

        if let floorY {
            let preferredCenter =
                floorY + WallPosterPlacementTuning.preferredCenterHeightMeters
            let minCenter =
                floorY +
                WallPosterPlacementTuning.minBottomClearanceMeters +
                height * 0.5

            desiredWorldY = max(
                preferredCenter,
                minCenter
            )
        } else {
            desiredWorldY = wall.center.y
        }

        let desiredLocalY: Float

        if abs(wall.up.y) > 0.05 {
            desiredLocalY = (desiredWorldY - wall.center.y) / wall.up.y
        } else {
            desiredLocalY = 0
        }

        let maxX = max(
            0,
            wall.width * 0.5 - width * 0.5 - WallPosterPlacementTuning.wallMarginMeters
        )
        let maxY = max(
            0,
            wall.height * 0.5 - height * 0.5 - WallPosterPlacementTuning.wallMarginMeters
        )
        let clampedY = min(
            max(
                desiredLocalY,
                -maxY
            ),
            maxY
        )

        let candidateXs: [Float] = [
            0,
            -maxX * 0.55,
            maxX * 0.55,
            -maxX,
            maxX
        ]

        var best: (placement: WallPosterPlacement, score: Float)?

        for x in candidateXs {
            let placement = WallPosterPlacement(
                wallID: wall.id,
                localX: x,
                localY: clampedY,
                depthOffset: WallPosterMetrics.depthOffset,
                width: width,
                height: height
            )
            let score = clearanceScore(
                placement: placement,
                wall: wall,
                floorY: floorY
            )

            if best == nil ||
               score > best!.score {
                best = (
                    placement,
                    score
                )
            }
        }

        guard let best,
              best.score > -999 else {
            return nil
        }

        let floorLog = floorY.map {
            String($0)
        } ?? "nil"

        print(
            """
            [WallPosterUI] best wall slot selected
              wallID: \(wall.id)
              floorY: \(floorLog)
              desiredWorldY: \(desiredWorldY)
              localY: \(best.placement.localY)
              posterHeight: \(height)
              posterWidth: \(width)
              centerHeightTuning: \(WallPosterPlacementTuning.preferredCenterHeightMeters)
            """
        )

        return best.placement
    }

    private func clearanceScore(
        placement: WallPosterPlacement,
        wall: WallCandidate,
        floorY: Float?
    ) -> Float {
        var score: Float = 1.0
        let rect = WallLocalRect(
            minX: placement.localX - placement.width * 0.5,
            minY: placement.localY - placement.height * 0.5,
            maxX: placement.localX + placement.width * 0.5,
            maxY: placement.localY + placement.height * 0.5
        )

        if occupancyRegistry?.hasHardOverlap(
            wallID: wall.id,
            candidate: rect.expanded(
                by: WallPosterPlacementTuning.portalCandidateExpansionMeters
            ),
            candidateKind: .wallPoster
        ) == true {
            print(
                """
                [WallPosterUI] candidate rejected by wall occupancy
                  wallID: \(wall.id)
                  reason: overlaps_existing_portal
                """
            )
            return -1000
        }

        if abs(wall.up.y) > 0.05 {
            let bottomWorldY =
                wall.center.y +
                wall.up.y * (placement.localY - placement.height * 0.5)
            let bottomAboveFloor = floorY.map {
                bottomWorldY - $0
            } ?? Float.greatestFiniteMagnitude

            guard bottomAboveFloor >= WallPosterPlacementTuning.minBottomClearanceMeters else {
                print(
                    """
                    [WallPosterUI] candidate rejected below floor-height minimum
                      wallID: \(wall.id)
                      bottomAboveFloorMeters: \(bottomAboveFloor)
                      requiredMeters: \(WallPosterPlacementTuning.minBottomClearanceMeters)
                    """
                )
                return -1000
            }

            score += min(
                1.0,
                bottomAboveFloor / WallPosterPlacementTuning.minBottomClearanceMeters
            )
        }

        score += abs(placement.localX) * 0.05

        return score
    }
}

private extension WallMountedPosterUIController {
    func registerPosterOccupancy(
        placement: WallPosterPlacement
    ) {
        guard let occupancyRegistry else {
            hasRegisteredOccupancy = false

            print(
                """
                [WallPosterUI] ERROR cannot register poster occupancy
                  reason: missing_wall_prop_occupancy_registry
                """
            )

            return
        }

        occupancyRegistry.unregister(
            id: posterOccupancyID
        )

        let stickerDepth =
            WallStickerStyle.stickerSizeMeters * 1.95 +
            WallStickerStyle.stickerSpacingMeters

        let rect = WallLocalRect(
            minX: placement.localX - placement.width * 0.5 - 0.08,
            minY: placement.localY - placement.height * 0.5 - stickerDepth,
            maxX: placement.localX + placement.width * 0.5 + 0.08,
            maxY: placement.localY + placement.height * 0.5 + 0.08
        )

        occupancyRegistry.register(
            id: posterOccupancyID,
            wallID: placement.wallID,
            kind: .wallPoster,
            rect: rect,
            padding: WallPosterPlacementTuning.occupancyPaddingMeters,
            label: "RealityKit wall poster UI + stickers"
        )
        hasRegisteredOccupancy = true

        print(
            """
            [WallPosterUI] poster occupancy registered
              wallID: \(placement.wallID)
              includesStickerRow: true
              rect: \(rect)
              padding: \(WallPosterPlacementTuning.occupancyPaddingMeters)
            """
        )
    }

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

        addWallStickerButtons(
            posterWidth: width,
            posterHeight: height
        )

        print(
            """
            [WallPosterUI] RealityKit poster panel created
              texture: plague_menu_ui_mockup
              widthMeters: \(width)
              heightMeters: \(height)
              maxHeightInches: \(WallPosterMetrics.maxHeightMeters / 0.0254)
              occupancyPaddingMeters: \(WallPosterPlacementTuning.occupancyPaddingMeters)
              physicallyBasedMaterial: true
            """
        )
    }

    func addWallStickerButtons(
        posterWidth: Float,
        posterHeight: Float
    ) {
        let size = min(
            WallStickerStyle.stickerSizeMeters,
            posterHeight * 0.105
        )
        let y = -posterHeight * 0.5 - size * 0.90
        let closeX = posterWidth * 0.5 - size * 0.65
        let trophyX =
            closeX -
            size -
            WallStickerStyle.stickerSpacingMeters

        addImageSticker(
            textureName: "trophy_sticker",
            name: "WallPosterLeaderboard_Trophy",
            position: SIMD3<Float>(
                trophyX,
                y,
                0.018
            ),
            size: size,
            component: WallPosterLeaderboardButtonComponent(
                id: "wall_poster_leaderboards"
            )
        )

        addImageSticker(
            textureName: "kill_switch_x",
            name: "WallPosterKillSwitch_X",
            position: SIMD3<Float>(
                closeX,
                y,
                0.018
            ),
            size: size,
            component: WallPosterKillSwitchComponent(
                id: "wall_poster_kill"
            )
        )

        print(
            """
            [WallPosterUI] bottom stickers created
              trophy: true
              closeX: true
              tint: two_stops_down
              pureWhite: false
            """
        )
    }

    func addImageSticker<C: Component>(
        textureName: String,
        name: String,
        position: SIMD3<Float>,
        size: Float,
        component: C
    ) {
        guard let texture = try? TextureResource.load(
            named: textureName
        ) else {
            print("[WallPosterUI] ERROR missing sticker texture \(textureName).png")
            return
        }

        var material = UnlitMaterial()
        material.color = .init(
            tint: WallStickerStyle.twoStopsDownTint,
            texture: .init(texture)
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: 0.92)
        )

        let sticker = ModelEntity(
            mesh: .generatePlane(
                width: size,
                height: size
            ),
            materials: [material]
        )

        sticker.name = name
        sticker.position = position
        sticker.components.set(component)
        sticker.components.set(InputTargetComponent())
        sticker.generateCollisionShapes(recursive: true)

        root.addChild(sticker)

        print(
            """
            [WallPosterUI] sticker created
              name: \(name)
              texture: \(textureName).png
              size: \(size)
              position: \(position)
              tintExposure: -2 stops
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
