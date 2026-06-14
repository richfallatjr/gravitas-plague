import Foundation
import RealityKit
import simd

@MainActor
final class HordePortalManager {
    private(set) var portals: [UUID: HordePortal] = [:]
    private var portalOrder: [UUID] = []
    private var entranceSideByPortalID: [UUID: HordePortalEntranceSide] = [:]
    private var transitionFXByPortalID: [UUID: PortalTransitionFXController] = [:]
    private var groundDiscByPortalID: [UUID: Entity] = [:]
    private let backdropOrientationLock = HordePortalBackdropOrientationLock(
        baseArtYawDegrees: 0
    )

    private weak var sceneRoot: Entity?
    private weak var wallManager: WallPlaneManager?
    private weak var occupancyRegistry: WallPropOccupancyRegistry?

    func install(
        sceneRoot: Entity,
        wallManager: WallPlaneManager,
        occupancyRegistry: WallPropOccupancyRegistry
    ) {
        self.sceneRoot = sceneRoot
        self.wallManager = wallManager
        self.occupancyRegistry = occupancyRegistry

        print(
            """
            [HordePortal] manager installed
              occupancyRegistry: true
            """
        )
    }

    func reset() {
        for id in portalOrder {
            occupancyRegistry?.unregister(
                id: id
            )
        }

        for fx in transitionFXByPortalID.values {
            fx.teardown()
        }
        transitionFXByPortalID.removeAll()

        for ground in groundDiscByPortalID.values {
            ground.removeFromParent()
        }
        groundDiscByPortalID.removeAll()

        for portal in portals.values {
            portal.root.removeFromParent()
        }

        portals.removeAll()
        portalOrder.removeAll()
        entranceSideByPortalID.removeAll()
        backdropOrientationLock.reset()

        print("[HordePortal] reset")
    }

    func updatePortalFX(
        deltaTime: Float
    ) {
        for fx in transitionFXByPortalID.values {
            fx.update(
                deltaTime: deltaTime
            )
        }
    }

    func createPortalForWave(
        wave: Int,
        spawnIndex: Int,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>,
        excludingPortalIDs: Set<UUID>
    ) async -> HordePortal? {
        guard let sceneRoot,
              let wallManager else {
            print("[HordePortal] ERROR manager not installed")
            return nil
        }

        guard let candidate = choosePortalPlacement(
            wave: wave,
            spawnIndex: spawnIndex,
            playerPosition: playerPosition,
            playerForward: playerForward,
            excludingPortalIDs: excludingPortalIDs
        ) else {
            print(
                """
                [HordePortal] no safe wall slot for new portal
                  wave: \(wave)
                  spawnIndex: \(spawnIndex)
                  existingPortals: \(portals.count)
                  reservedThisWave: \(excludingPortalIDs.count)
                  action: reuse_existing_portal_instead_of_overlapping_poster
                """
            )
            return nil
        }

        let wall = candidate.wall
        var placement = candidate.placement
        let seed = UInt64(wave) ^ UInt64(portalOrder.count * 7919)
        let profile = HordePortalApertureProfile.random(
            baseWidth: placement.width,
            baseHeight: placement.height,
            seed: seed
        )

        print(
            """
            [HordePortal] straight-top janky aperture created
              bottomFlush: true
              topShape: straight_line_between_side_tops
              leftHeight: \(profile.leftHeight)
              rightHeight: \(profile.rightHeight)
              leftTopLean: \(profile.leftTopLean)
              rightTopLean: \(profile.rightTopLean)
              noSquiggleTop: true
            """
        )

        placement.height = profile.maxHeight

        guard let resolvedPlacement = wallManager.resolveFloorLockedPlacement(
            placement,
            requirement: .required
        ) else {
            print("[HordePortal] ERROR could not floor-lock janky aperture")
            return nil
        }

        placement = resolvedPlacement

        guard let occupancyRegistry else {
            print(
                """
                [HordePortal] FATAL missing occupancy registry after placement
                  action: block_portal_creation_to_protect_wall_ui
                """
            )
            return nil
        }

        let finalCandidateRect = wallRect(
            for: placement
        ).expanded(
            by: WallPosterPlacementTuning.portalCandidateExpansionMeters
        )

        if occupancyRegistry.hasHardOverlap(
            wallID: wall.id,
            candidate: finalCandidateRect,
            candidateKind: .hordePortal
        ) {
            print(
                """
                [HordePortal] final portal placement rejected by wall occupancy
                  wave: \(wave)
                  spawnIndex: \(spawnIndex)
                  wallID: \(wall.id)
                  localX: \(placement.localX)
                  localY: \(placement.localY)
                  rect: \(finalCandidateRect)
                  action: reuse_existing_portal_instead_of_overlapping_poster
                """
            )
            return nil
        }

        let portalID = UUID()
        let root = Entity()
        root.name = "HordePortalRoot_wave\(wave)_\(UUID().uuidString.prefix(6))"

        let portalWorld = Entity()
        portalWorld.name = "HordePortalWorld_wave\(wave)"
        portalWorld.components.set(WorldComponent())
        PlagueNativeBloomInstaller.installStrictBloom(
            on: portalWorld
        )

        let context = PortalContentContext.forDoor(
            width: placement.width,
            height: placement.height
        )

        do {
            try await HordeHellscapePortalContentProvider()
                .populatePortalWorld(
                    portalWorld: portalWorld,
                    context: context
                )
        } catch {
            print(
                """
                [HordePortal] ERROR hellscape portal content failed
                  wave: \(wave)
                  error: \(error.localizedDescription)
                """
            )
            return nil
        }

        let groundFloorY = context.floorY + 0.004

        do {
            let groundDisc = try HordePortalGroundDiscFactory.makeGroundDisc(
                config: .init(
                    floorY: groundFloorY,
                    centerZ: context.groundDiscCenterZ,
                    radius: context.groundDiscRadius,
                    segments: 96,
                    featherRingCount: 8,
                    featherStartFraction: 0.72,
                    textureName: "hellscape_groundplane",
                    exposure: 1.0
                )
            )

            portalWorld.addChild(groundDisc)
            groundDiscByPortalID[portalID] = groundDisc

            print(
                """
                [HordePortal] faded ground disc attached
                  portalID: \(portalID)
                  parent: portalWorldRoot
                  floorY: \(groundFloorY)
                  centerZ: \(context.groundDiscCenterZ)
                  radius: \(context.groundDiscRadius)
                  geometry: circular_disc_with_faded_edge
                  placementSource: committed_portal_context
                  notBackdropRoot: true
                """
            )
        } catch {
            print(
                """
                [HordePortalGroundDisc] ERROR faded disc build failed
                  portalID: \(portalID)
                  error: \(error.localizedDescription)
                  action: continue_without_ground_disc_no_fallback
                """
            )
        }

        let portalPlane: ModelEntity

        do {
            portalPlane = try HordePortalApertureMeshFactory.makePortalPlane(
                profile: profile,
                targetWorld: portalWorld
            )
            portalPlane.position.z = -0.040

            if HordePortalSoftWallFeatherFactory.enabled {
                let feather = try HordePortalSoftWallFeatherFactory.makeFeather(
                    profile: profile,
                    seed: seed
                )

                root.addChild(feather)
            }
        } catch {
            print(
                """
                [HordePortal] ERROR failed to build janky aperture
                  wave: \(wave)
                  error: \(error.localizedDescription)
                """
            )
            return nil
        }

        root.addChild(portalPlane)
        root.addChild(portalWorld)

        if root.findEntity(named: "HordePortalWallOcclusionMask") != nil {
            fatalError("[HordePortal] wall occlusion mask still present. Remove it.")
        }

        guard let transform = wallManager.convertWallLocalToWorldTransform(
            placement: placement
        ) else {
            print("[HordePortal] ERROR could not build wall transform")
            return nil
        }

        let perimeterPoints = HordePortalApertureMeshFactory.makeBoundary3D(
            profile: profile
        ).map {
            SIMD3<Float>(
                $0.x,
                $0.y,
                0.018
            )
        }

        let transitionFX = PortalTransitionFXController(
            perimeterLocalPoints: perimeterPoints,
            portalNormalLocal: SIMD3<Float>(0, 0, 1)
        )

        transitionFX.build()
        root.addChild(transitionFX.rootEntity)
        transitionFXByPortalID[portalID] = transitionFX

        print(
            """
            [HordePortal] transition FX attached
              portalID: \(portalID)
              perimeterPoints: \(perimeterPoints.count)
              tube: true
              embers: true
              bloom: true
            """
        )

        print(
            """
            [HordePortal] bloom-driving materials active
              tubeEmissiveIntensity: \(PortalFXDefaults.tubeEmissiveIntensity)
              bloomTargetStrength: \(PortalFXDefaults.bloomTargetStrength)
            """
        )

        root.setTransformMatrix(
            transform,
            relativeTo: nil
        )

        if let backdropRoot = portalWorld.findEntity(
            named: "HordeHellscapeBackdropRoot"
        ) {
            backdropOrientationLock.applyBackdropOrientation(
                to: backdropRoot,
                portalRoot: root,
                portalID: portalID,
                label: "wave_\(wave)_spawn_\(spawnIndex)"
            )
        } else {
            print(
                """
                [HordePortalBackdrop] ERROR missing backdrop root
                  portalID: \(portalID)
                  expected: HordeHellscapeBackdropRoot
                  result: domeWillUseDefaultOrientation
                """
            )
        }

        assertNoEnemyUnderBackdropRoot(
            portalWorld: portalWorld,
            portalID: portalID
        )

        sceneRoot.addChild(root)
        logFloorAnchorProof(
            placement: placement,
            wall: wall
        )
        logStrictHordeFloorLockProof(
            placement: placement,
            wall: wall
        )

        let worldCenter = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let bearing = atan2(
            worldCenter.x - playerPosition.x,
            worldCenter.z - playerPosition.z
        )

        let portal = HordePortal(
            id: portalID,
            waveCreated: wave,
            wallID: wall.id,
            placement: placement,
            apertureProfile: profile,
            root: root,
            portalWorldRoot: portalWorld,
            portalPlane: portalPlane,
            resolvedFloorWorldY: placement.floorWorldY,
            worldCenter: worldCenter,
            bearingFromPlayerRadians: bearing,
            entranceCount: 0
        )

        portals[portalID] = portal
        portalOrder.append(portalID)
        registerPortalOccupancy(
            portalID: portalID,
            placement: placement
        )

        print(
            """
            [HordePortal] portal created
              wave: \(wave)
              spawnIndex: \(spawnIndex)
              portalID: \(portalID)
              wallID: \(wall.id)
              localX: \(placement.localX)
              localY: \(placement.localY)
              width: \(placement.width)
              height: \(placement.height)
              nearestExistingM: \(candidate.nearestPortalDistance)
              nearestReservedM: \(candidate.nearestReservedDistance)
              posterClearanceM: \(candidate.posterClearanceDistance)
              nearestBearingGapRad: \(candidate.nearestBearingGap)
              backdrop: hellscape_01.exr
              persists: true
            """
        )

        print(
            """
            [HordePortal] janky aperture portal created
              wave: \(wave)
              width: \(profile.bottomWidth)
              maxHeight: \(profile.maxHeight)
              leftHeight: \(profile.leftHeight)
              rightHeight: \(profile.rightHeight)
              leftTopLean: \(profile.leftTopLean)
              rightTopLean: \(profile.rightTopLean)
              hardFrameRemoved: true
              bottomFlushToFloor: true
            """
        )

        print(
            """
            [HordePortal] portal created with real portal aperture
              renderInstancePortalEnemySupported: true
              noFade: true
              noWallOcclusionMask: true
              portalBackdropBehindMask: true
            """
        )

        return portal
    }

    func reapplyBackdropOrientationsToAllPortals() {
        for portal in portals.values {
            guard let backdropRoot = portal.portalWorldRoot.findEntity(
                named: "HordeHellscapeBackdropRoot"
            ) else {
                print(
                    """
                    [HordePortalBackdrop] ERROR missing backdrop root during reapply
                      portalID: \(portal.id)
                      expected: HordeHellscapeBackdropRoot
                    """
                )
                continue
            }

            backdropOrientationLock.applyBackdropOrientation(
                to: backdropRoot,
                portalRoot: portal.root,
                portalID: portal.id,
                label: "reapply"
            )
        }
    }

    func bestUnreservedPortal(
        excluding reserved: Set<UUID>,
        playerPosition: SIMD3<Float>
    ) -> HordePortal? {
        let candidates = portals.values.filter {
            !reserved.contains($0.id)
        }

        guard !candidates.isEmpty else {
            return nil
        }

        return candidates.sorted { lhs, rhs in
            if lhs.entranceCount != rhs.entranceCount {
                return lhs.entranceCount < rhs.entranceCount
            }

            let lhsDistance = simd_length(lhs.worldCenter - playerPosition)
            let rhsDistance = simd_length(rhs.worldCenter - playerPosition)

            return lhsDistance > rhsDistance
        }.first
    }

    func leastUsedPortal() -> HordePortal? {
        portals.values.sorted { lhs, rhs in
            if lhs.entranceCount != rhs.entranceCount {
                return lhs.entranceCount < rhs.entranceCount
            }

            return lhs.waveCreated < rhs.waveCreated
        }.first
    }

    func nextEntranceSide(
        portalID: UUID
    ) -> HordePortalEntranceSide {
        let current = entranceSideByPortalID[portalID] ?? .left
        let next: HordePortalEntranceSide = current == .left ? .right : .left
        entranceSideByPortalID[portalID] = next
        return current
    }

    func occupiedWallRects(
        wallID: UUID
    ) -> [SIMD4<Float>] {
        portals.values
            .filter {
                $0.wallID == wallID
            }
            .map { portal in
                let placement = portal.placement

                return SIMD4<Float>(
                    placement.localX - placement.width * 0.5 - 0.24,
                    placement.localY - placement.height * 0.5 - 0.24,
                    placement.width + 0.48,
                    placement.height + 0.48
                )
            }
    }

    func markEntranceUsed(
        portalID: UUID
    ) {
        guard var portal = portals[portalID] else {
            return
        }

        portal.entranceCount += 1
        portals[portalID] = portal
    }

    private func choosePortalPlacement(
        wave: Int,
        spawnIndex: Int,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>,
        excludingPortalIDs: Set<UUID>
    ) -> HordePortalPlacementCandidate? {
        guard let wallManager else {
            return nil
        }
        guard let occupancyRegistry else {
            print(
                """
                [HordePortalPlacement] FATAL missing occupancy registry
                  action: block_portal_creation_to_protect_wall_ui
                """
            )
            return nil
        }
        _ = playerForward

        let existingCenters = portals.values.map(\.worldCenter)
        let reservedCenters = portals.values
            .filter { excludingPortalIDs.contains($0.id) }
            .map(\.worldCenter)

        let walls = wallManager.wallCandidates.values
            .filter { $0.isLargeEnoughForDefaultDoor }

        guard !walls.isEmpty else {
            return nil
        }

        var candidates: [HordePortalPlacementCandidate] = []

        for wall in walls {
            guard wallManager.bestFloorCandidate(near: wall) != nil else {
                print(
                    """
                    [HordePortalPlacement] wall skipped
                      wallID: \(wall.id)
                      reason: no_verified_floor_near_wall
                    """
                )
                continue
            }

            for slot in generateWallSlots(
                wall: wall
            ) {
                var placement = slot
                guard let resolved = wallManager.resolveFloorLockedPlacement(
                    placement,
                    requirement: .required
                ) else {
                    print("[HordePortal] skipped portal placement: no verified floor")
                    continue
                }

                placement = resolved
                let rect = wallRect(
                    for: placement
                )

                let candidateRect = rect.expanded(
                    by: WallPosterPlacementTuning.portalCandidateExpansionMeters
                )

                if occupancyRegistry.hasHardOverlap(
                    wallID: wall.id,
                    candidate: candidateRect,
                    candidateKind: .hordePortal
                ) {
                    print(
                        """
                        [HordePortalPlacement] rejected candidate
                          wave: \(wave)
                          spawnIndex: \(spawnIndex)
                          reason: overlaps_wall_poster_or_existing_portal
                          wallID: \(wall.id)
                          localX: \(placement.localX)
                          localY: \(placement.localY)
                          rect: \(candidateRect)
                        """
                    )
                    continue
                }

                guard let transform = wallManager.convertWallLocalToWorldTransform(
                    placement: placement
                ) else {
                    continue
                }

                let center = SIMD3<Float>(
                    transform.columns.3.x,
                    transform.columns.3.y,
                    transform.columns.3.z
                )

                let bearing = atan2(
                    center.x - playerPosition.x,
                    center.z - playerPosition.z
                )

                let nearestExisting = nearestDistance(
                    center,
                    to: existingCenters
                )
                let nearestRegisteredPortal = occupancyRegistry.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.hordePortal]
                )
                let posterDistance = occupancyRegistry.nearestDistance(
                    wallID: wall.id,
                    candidate: rect,
                    kinds: [.wallPoster]
                )
                let nearestPortalDistance = min(
                    nearestExisting,
                    nearestRegisteredPortal
                )
                let nearestReserved = nearestDistance(
                    center,
                    to: reservedCenters
                )
                let bearingGap = nearestExistingPortalBearingGap(
                    bearing
                )
                let spacingOK =
                    nearestPortalDistance >= HordePortalPlacementTuning.minSpacingMeters &&
                    nearestReserved >= HordePortalPlacementTuning.minSpacingMeters

                let spacingScore = min(
                    1,
                    min(
                        nearestPortalDistance,
                        nearestReserved
                    ) / HordePortalPlacementTuning.preferredSpacingMeters
                )
                let posterClearanceScore = min(
                    1,
                    posterDistance / 1.0
                )
                let angularScore = min(
                    1,
                    bearingGap / (.pi / 3)
                )

                let score =
                    spacingScore * 3.0 +
                    posterClearanceScore * 5.0 +
                    angularScore * 2.0 +
                    Float.random(in: 0...0.20)

                candidates.append(
                    HordePortalPlacementCandidate(
                        wall: wall,
                        placement: placement,
                        worldCenter: center,
                        bearingRadians: bearing,
                        nearestPortalDistance: nearestPortalDistance,
                        nearestReservedDistance: nearestReserved,
                        posterClearanceDistance: posterDistance,
                        nearestBearingGap: bearingGap,
                        spacingOK: spacingOK,
                        score: score
                    )
                )
            }
        }

        let valid = candidates.filter(\.spacingOK)

        let chosen = (valid.isEmpty ? candidates : valid)
            .max { lhs, rhs in
                lhs.score < rhs.score
            }

        if let chosen {
            print(
                """
                [HordePortalPlacement] chosen
                  wave: \(wave)
                  spawnIndex: \(spawnIndex)
                  wallID: \(chosen.wall.id)
                  localX: \(chosen.placement.localX)
                  localY: \(chosen.placement.localY)
                  nearestPortalDistanceM: \(chosen.nearestPortalDistance)
                  nearestReservedM: \(chosen.nearestReservedDistance)
                  posterClearanceM: \(chosen.posterClearanceDistance)
                  bearingGapRad: \(chosen.nearestBearingGap)
                  rejectedPosterOverlap: false
                  spacingOK: \(chosen.spacingOK)
                  score: \(chosen.score)
                """
            )
        }

        if chosen == nil {
            print(
                """
                [HordePortalPlacement] ERROR no floor-verified portal placement available
                  walls: \(walls.count)
                  floors: \(wallManager.floorCandidates.count)
                  action: keep_scanning_do_not_spawn_air_portal
                """
            )
        }

        return chosen
    }

    private func generateWallSlots(
        wall: WallCandidate
    ) -> [DoorPlacement] {
        let widths: [Float] = [0.82, 0.92, 1.05]
        let heights: [Float] = [1.90, 2.05, 2.18]
        var placements: [DoorPlacement] = []

        for width in widths {
            for height in heights {
                var base = DoorPlacement.defaultForWall(wall)
                base.floorLocked = true
                base.confirmed = true
                base.contentProviderID = HordeHellscapePortalContentProvider.providerID
                base.width = width
                base.height = height

                let maxX = max(
                    0,
                    wall.width * 0.5 - width * 0.5 - 0.10
                )

                let spacing = max(
                    HordePortalPlacementTuning.minSpacingMeters,
                    width + 0.20
                )

                guard maxX > 0.01 else {
                    placements.append(base)
                    continue
                }

                var x = -maxX
                while x <= maxX + 0.001 {
                    var placement = base
                    placement.localX = x
                    placements.append(placement)
                    x += spacing
                }

                if !placements.contains(where: { existing in
                    existing.wallID == base.wallID &&
                    abs(existing.localX) < 0.01 &&
                    abs(existing.width - base.width) < 0.001 &&
                    abs(existing.height - base.height) < 0.001
                }) {
                    var center = base
                    center.localX = 0
                    placements.append(center)
                }
            }
        }

        return placements
    }

    private func nearestDistance(
        _ point: SIMD3<Float>,
        to points: [SIMD3<Float>]
    ) -> Float {
        guard !points.isEmpty else {
            return Float.greatestFiniteMagnitude
        }

        return points.map {
            simd_length($0 - point)
        }.min() ?? Float.greatestFiniteMagnitude
    }

    private func nearestExistingPortalDistance(
        to center: SIMD3<Float>
    ) -> Float {
        guard !portals.isEmpty else {
            return Float.greatestFiniteMagnitude
        }

        return portals.values.map {
            simd_length($0.worldCenter - center)
        }.min() ?? Float.greatestFiniteMagnitude
    }

    private func nearestExistingPortalBearingGap(
        _ bearing: Float
    ) -> Float {
        guard !portals.isEmpty else {
            return .pi
        }

        return portals.values.map {
            abs(
                shortestAngleDelta(
                    from: $0.bearingFromPlayerRadians,
                    to: bearing
                )
            )
        }.min() ?? .pi
    }

    private func shortestAngleDelta(
        from a: Float,
        to b: Float
    ) -> Float {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    private func wallRect(
        for placement: DoorPlacement
    ) -> WallLocalRect {
        WallLocalRect(
            minX: placement.localX - placement.width * 0.5,
            minY: placement.localY - placement.height * 0.5,
            maxX: placement.localX + placement.width * 0.5,
            maxY: placement.localY + placement.height * 0.5
        )
    }

    private func registerPortalOccupancy(
        portalID: UUID,
        placement: DoorPlacement
    ) {
        occupancyRegistry?.register(
            id: portalID,
            wallID: placement.wallID,
            kind: .hordePortal,
            rect: wallRect(
                for: placement
            ),
            padding: 0.46,
            label: "Horde portal"
        )
    }

    private func assertNoEnemyUnderBackdropRoot(
        portalWorld: Entity,
        portalID: UUID
    ) {
        guard let backdrop = portalWorld.findEntity(
            named: "HordeHellscapeBackdropRoot"
        ) else {
            return
        }

        for child in backdrop.children {
            if child.name.contains("Enemy") ||
                child.name.contains("PortalRenderInstance") ||
                child.name.contains("Jock") ||
                child.name.contains("HordePortalGroundDiscRoot") {
                print(
                    """
                    [HordePortalBackdrop] ERROR non-backdrop entity under backdrop root
                      portalID: \(portalID)
                      child: \(child.name)
                      action: move_to_portalWorldRoot
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

    private func logStrictHordeFloorLockProof(
        placement: DoorPlacement,
        wall: WallCandidate
    ) {
        let bottomWorld =
            wall.center +
            wall.right * placement.localX +
            wall.up * (placement.localY - placement.height * 0.5)

        if let floorY = placement.floorWorldY {
            let delta = bottomWorld.y - floorY

            if abs(delta - placement.bottomClearance) > 0.08 {
                print(
                    """
                    [HordePortal] ERROR portal bottom is not floor locked
                      wallID: \(wall.id)
                      bottomWorldY: \(bottomWorld.y)
                      floorY: \(floorY)
                      delta: \(delta)
                      bottomClearance: \(placement.bottomClearance)
                      likelyBug: ceiling_or_wrong_floor_selected
                    """
                )
            } else {
                print(
                    """
                    [HordePortal] floor lock proof
                      wallID: \(wall.id)
                      bottomWorldY: \(bottomWorld.y)
                      floorY: \(floorY)
                      delta: \(delta)
                      accepted: true
                    """
                )
            }
        } else {
            print(
                """
                [HordePortal] ERROR portal has no floorWorldY
                  wallID: \(wall.id)
                  action: should_not_happen_for_horde
                """
            )
        }
    }

}
