import Combine
import RealityKit
import UIKit
import simd

enum WallPosterPlacementState: String {
    case notPlaced
    case locked
}

@MainActor
final class WallMountedPosterUIController: ObservableObject {
    private struct CommittedWallPosterPlacement {
        let candidatePlacement: WallPosterPlacement
        let worldTransform: simd_float4x4
        let occupancyID: UUID
    }

    private(set) var root = Entity()
    private let contentRoot = Entity()
    private var posterEntity: ModelEntity?
    private var buttonEntities: [Entity] = []
    private let dayNightIconController = TuringStoryPosterDayNightIconController()

    private weak var wallManager: WallPlaneManager?
    private weak var hordePortalManager: HordePortalManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    private var currentPlacement: WallPosterPlacement?
    private var currentPosterSize: SIMD2<Float>?
    private(set) var placementState: WallPosterPlacementState = .notPlaced
    private var committedPlacement: CommittedWallPosterPlacement?
    private var lastAppliedPosition: SIMD3<Float>?
    private let posterOccupancyID = UUID()
    private(set) var hasRegisteredOccupancy = false

    var isLocked: Bool {
        placementState == .locked &&
            committedPlacement != nil
    }

    var isPlaced: Bool {
        isLocked
    }

    func updateTuringWindowDayNightIcon(
        atmosphere: PortalHDRIAtmosphere
    ) {
        dayNightIconController.update(
            atmosphere: atmosphere
        )
    }

    init() {
        WallPosterUIButtonComponent.registerComponent()
        WallPosterKillSwitchComponent.registerComponent()
        WallPosterLeaderboardButtonComponent.registerComponent()
        TuringStoryDayNightPosterButtonComponent.registerComponent()
        root.name = "WallPosterWorldLockedRoot"
        contentRoot.name = "WallPosterMutableContentRoot"
        root.addChild(contentRoot)
        root.isEnabled = false
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

        if contentRoot.parent == nil {
            root.addChild(contentRoot)
        }

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
        _ = force

        guard !isLocked else {
            return true
        }

        guard placementState == .notPlaced,
              committedPlacement == nil else {
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

        guard let transform = worldTransform(
            for: placement
        ) else {
            print(
                """
                [WallPosterUI] ERROR could not compute committed world transform
                  wallID: \(placement.wallID)
                """
            )
            return false
        }

        root.isEnabled = false

        rebuildPosterIfNeeded(
            width: placement.width,
            height: placement.height
        )

        guard let occupancyID = registerPosterOccupancy(
            placement: placement
        ) else {
            return false
        }

        root.setTransformMatrix(
            transform,
            relativeTo: nil
        )

        currentPlacement = placement
        committedPlacement = CommittedWallPosterPlacement(
            candidatePlacement: placement,
            worldTransform: transform,
            occupancyID: occupancyID
        )
        placementState = .locked
        lastAppliedPosition = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        root.isEnabled = true

        print(
            """
            [WallPosterUI] placement committed permanently
              wallID: \(placement.wallID)
              width: \(placement.width)
              height: \(placement.height)
              localX: \(placement.localX)
              localY: \(placement.localY)
              depthOffset: \(placement.depthOffset)
              worldPosition: \(String(describing: lastAppliedPosition))
              state: locked
              transformWillRefresh: false
            """
        )

        #if DEBUG
        assertLockedTransformUnchanged()
        #endif

        return true
    }

    func reset() {
        resetPlacement(
            reason: "reset"
        )
    }

    func resetPlacement(
        reason: String
    ) {
        if let committedPlacement {
            occupancyRegistry?.unregister(
                id: committedPlacement.occupancyID
            )
        } else {
            occupancyRegistry?.unregister(
                id: posterOccupancyID
            )
        }

        committedPlacement = nil
        currentPlacement = nil
        currentPosterSize = nil
        placementState = .notPlaced
        lastAppliedPosition = nil
        hasRegisteredOccupancy = false
        posterEntity = nil
        buttonEntities.removeAll()
        contentRoot.children.removeAll()
        root.isEnabled = false
        root.transform = .identity

        print(
            """
            [WallPosterUI] placement explicitly reset
              reason: \(reason)
            """
        )
    }

    #if DEBUG
    func assertLockedTransformUnchanged(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard let committedPlacement else {
            return
        }

        let actual = root.transformMatrix(
            relativeTo: nil
        )

        guard matricesApproximatelyEqual(
            actual,
            committedPlacement.worldTransform
        ) else {
            assertionFailure(
                """
                [WallPosterUI] LOCKED POSTER TRANSFORM WAS MUTATED.
                No code may reposition the poster after commit.
                """,
                file: file,
                line: line
            )
            return
        }
    }
    #endif

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
    ) -> UUID? {
        guard let occupancyRegistry else {
            hasRegisteredOccupancy = false

            print(
                """
                [WallPosterUI] ERROR cannot register poster occupancy
                  reason: missing_wall_prop_occupancy_registry
                """
            )

            return nil
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

        return posterOccupancyID
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
            return
        }

        contentRoot.children.removeAll()
        buttonEntities.removeAll()
        posterEntity = nil
        currentPosterSize = newSize

        OperationModePosterResources.shared.loadIfNeeded()

        var material = UnlitMaterial()

        if let texture = OperationModePosterResources.shared.posterTexture {
            material.color = .init(
                tint: .white,
                texture: .init(texture)
            )
        } else {
            material.color = .init(
                tint: .darkGray
            )

            print(
                """
                [WallPosterUI] ERROR missing operation mode poster texture
                  texture: \(OperationModePosterLayout.assetName).\(OperationModePosterLayout.assetExtension)
                """
            )
        }

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

        contentRoot.addChild(poster)
        posterEntity = poster

        addModeHitTarget(
            region: OperationModePosterLayout.storyRegion,
            posterWidth: width,
            posterHeight: height
        )

        addModeHitTarget(
            region: OperationModePosterLayout.hordeRegion,
            posterWidth: width,
            posterHeight: height
        )

        addWallStickerButtons(
            posterWidth: width,
            posterHeight: height
        )

        print(
            """
            [WallPosterUI] RealityKit poster panel created
              texture: \(OperationModePosterLayout.assetName).\(OperationModePosterLayout.assetExtension)
              widthMeters: \(width)
              heightMeters: \(height)
              maxHeightInches: \(WallPosterMetrics.maxHeightMeters / 0.0254)
              occupancyPaddingMeters: \(WallPosterPlacementTuning.occupancyPaddingMeters)
              material: unlit
              walkLoopPlayerFacing: false
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

        dayNightIconController.install(
            posterContentRoot: contentRoot,
            posterWidth: posterWidth,
            posterHeight: posterHeight,
            atmosphere: .night
        )

        print(
            """
            [WallPosterUI] bottom stickers created
              trophy: true
              closeX: true
              dayNightWindow: true
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

        contentRoot.addChild(sticker)

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

    func addModeHitTarget(
        region: PosterModeRegion,
        posterWidth: Float,
        posterHeight: Float
    ) {
        guard let action = WallPosterAction(
            rawValue: region.mode.rawValue
        ) else {
            print(
                """
                [WallPosterUI] ERROR no wall action for poster mode
                  mode: \(region.mode.rawValue)
                """
            )
            return
        }

        let availability = OperationModeAccessController.shared.snapshot[
            region.mode
        ]
        let mapped = PosterCoordinateMapper.realityKitRect(
            normalizedRect: region.normalizedRect,
            posterWidthMeters: posterWidth,
            posterHeightMeters: posterHeight
        )

        let hit = ModelEntity(
            mesh: .generatePlane(
                width: mapped.size.x,
                height: mapped.size.y
            ),
            materials: [makeInvisibleHitMaterial()]
        )

        hit.name = "WallPosterButton_\(region.mode.rawValue)"
        hit.position = SIMD3<Float>(
            mapped.center.x,
            mapped.center.y,
            0.012
        )
        hit.components.set(
            WallPosterUIButtonComponent(
                actionRawValue: action.rawValue
            )
        )

        if availability.isUnlocked {
            hit.components.set(InputTargetComponent())
        }

        hit.generateCollisionShapes(recursive: true)

        contentRoot.addChild(hit)
        buttonEntities.append(hit)

        if !availability.isUnlocked {
            addProgrammaticLockIcon(
                center: mapped.center,
                regionSize: mapped.size,
                mode: region.mode
            )
        }

        print(
            """
            [WallPosterUI] button hit target created
              name: \(hit.name)
              action: \(action.rawValue)
              unlocked: \(availability.isUnlocked)
              localX: \(mapped.center.x)
              localY: \(mapped.center.y)
              width: \(mapped.size.x)
              height: \(mapped.size.y)
              posterWidth: \(posterWidth)
              posterHeight: \(posterHeight)
            """
        )
    }

    func addProgrammaticLockIcon(
        center: SIMD2<Float>,
        regionSize: SIMD2<Float>,
        mode: PlagueDemoSession.PlagueOperationMode
    ) {
        let color = OperationModePosterResources.shared.lockUIColor
        var material = UnlitMaterial()
        material.color = .init(
            tint: color
        )

        let lockRoot = Entity()
        lockRoot.name = "WallPosterLock_\(mode.rawValue)"
        lockRoot.position = SIMD3<Float>(
            center.x,
            center.y,
            0.019
        )

        let bodyWidth = max(
            0.018,
            regionSize.x * 0.12
        )
        let bodyHeight = max(
            0.012,
            regionSize.y * 0.22
        )
        let barThickness = max(
            0.004,
            min(bodyWidth, bodyHeight) * 0.18
        )

        func makeBar(
            name: String,
            width: Float,
            height: Float,
            position: SIMD3<Float>
        ) -> ModelEntity {
            let entity = ModelEntity(
                mesh: .generatePlane(
                    width: width,
                    height: height
                ),
                materials: [material]
            )

            entity.name = name
            entity.position = position
            entity.components.remove(InputTargetComponent.self)
            entity.components.remove(CollisionComponent.self)

            return entity
        }

        let body = makeBar(
            name: "WallPosterLockBody_\(mode.rawValue)",
            width: bodyWidth,
            height: bodyHeight,
            position: .zero
        )

        let shackleY = bodyHeight * 0.58
        let shackleSideX = bodyWidth * 0.32
        let shackleHeight = bodyHeight * 0.82

        let top = makeBar(
            name: "WallPosterLockTop_\(mode.rawValue)",
            width: bodyWidth * 0.64,
            height: barThickness,
            position: SIMD3<Float>(
                0,
                shackleY + shackleHeight * 0.5,
                0.001
            )
        )
        let left = makeBar(
            name: "WallPosterLockLeft_\(mode.rawValue)",
            width: barThickness,
            height: shackleHeight,
            position: SIMD3<Float>(
                -shackleSideX,
                shackleY,
                0.001
            )
        )
        let right = makeBar(
            name: "WallPosterLockRight_\(mode.rawValue)",
            width: barThickness,
            height: shackleHeight,
            position: SIMD3<Float>(
                shackleSideX,
                shackleY,
                0.001
            )
        )

        lockRoot.addChild(top)
        lockRoot.addChild(left)
        lockRoot.addChild(right)
        lockRoot.addChild(body)

        contentRoot.addChild(lockRoot)
        buttonEntities.append(lockRoot)

        print(
            """
            [WallPosterUI] lock icon created
              mode: \(mode.rawValue)
              color: \(color)
              source: sampled_darkest_opaque_pixel
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

    func worldTransform(
        for placement: WallPosterPlacement
    ) -> simd_float4x4? {
        guard let wallManager,
              let wall = wallManager.wallCandidates[placement.wallID] else {
            return nil
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

        return matrix
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

#if DEBUG
private func matricesApproximatelyEqual(
    _ lhs: simd_float4x4,
    _ rhs: simd_float4x4,
    epsilon: Float = 0.0005
) -> Bool {
    simd_length(lhs.columns.0 - rhs.columns.0) < epsilon &&
        simd_length(lhs.columns.1 - rhs.columns.1) < epsilon &&
        simd_length(lhs.columns.2 - rhs.columns.2) < epsilon &&
        simd_length(lhs.columns.3 - rhs.columns.3) < epsilon
}
#endif
