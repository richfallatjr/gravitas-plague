import Foundation
import RealityKit
import simd

@MainActor
final class HordePortalManager {
    private(set) var portals: [UUID: HordePortal] = [:]
    private var portalOrder: [UUID] = []
    private var entranceSideByPortalID: [UUID: HordePortalEntranceSide] = [:]

    private weak var sceneRoot: Entity?
    private weak var wallManager: WallPlaneManager?

    func install(
        sceneRoot: Entity,
        wallManager: WallPlaneManager
    ) {
        self.sceneRoot = sceneRoot
        self.wallManager = wallManager

        print("[HordePortal] manager installed")
    }

    func reset() {
        for portal in portals.values {
            portal.root.removeFromParent()
        }

        portals.removeAll()
        portalOrder.removeAll()
        entranceSideByPortalID.removeAll()

        print("[HordePortal] reset")
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
                [HordePortal] no unique portal placement available
                  wave: \(wave)
                  spawnIndex: \(spawnIndex)
                  existingPortals: \(portals.count)
                  reservedThisWave: \(excludingPortalIDs.count)
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

        placement.height = profile.maxHeight

        guard let resolvedPlacement = wallManager.resolveFloorLockedPlacement(
            placement,
            requirement: .required
        ) else {
            print("[HordePortal] ERROR could not floor-lock janky aperture")
            return nil
        }

        placement = resolvedPlacement

        let root = Entity()
        root.name = "HordePortalRoot_wave\(wave)_\(UUID().uuidString.prefix(6))"

        let portalWorld = Entity()
        portalWorld.name = "HordePortalWorld_wave\(wave)"
        portalWorld.components.set(WorldComponent())

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

        let portalPlane: ModelEntity

        do {
            portalPlane = try HordePortalApertureMeshFactory.makePortalPlane(
                profile: profile,
                targetWorld: portalWorld
            )

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

        guard let transform = wallManager.convertWallLocalToWorldTransform(
            placement: placement
        ) else {
            print("[HordePortal] ERROR could not build wall transform")
            return nil
        }

        root.setTransformMatrix(
            transform,
            relativeTo: nil
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
            id: UUID(),
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

        portals[portal.id] = portal
        portalOrder.append(portal.id)

        print(
            """
            [HordePortal] portal created
              wave: \(wave)
              spawnIndex: \(spawnIndex)
              portalID: \(portal.id)
              wallID: \(wall.id)
              localX: \(placement.localX)
              localY: \(placement.localY)
              width: \(placement.width)
              height: \(placement.height)
              nearestExistingM: \(candidate.nearestPortalDistance)
              nearestReservedM: \(candidate.nearestReservedDistance)
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

        return portal
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
                let nearestReserved = nearestDistance(
                    center,
                    to: reservedCenters
                )
                let bearingGap = nearestExistingPortalBearingGap(
                    bearing
                )
                let spacingOK =
                    nearestExisting >= HordePortalPlacementTuning.minSpacingMeters &&
                    nearestReserved >= HordePortalPlacementTuning.minSpacingMeters

                let spacingScore = min(
                    1,
                    min(
                        nearestExisting,
                        nearestReserved
                    ) / HordePortalPlacementTuning.preferredSpacingMeters
                )
                let angularScore = min(
                    1,
                    bearingGap / (.pi / 3)
                )

                let score =
                    spacingScore * 3.0 +
                    angularScore * 2.0 +
                    Float.random(in: 0...0.25)

                candidates.append(
                    HordePortalPlacementCandidate(
                        wall: wall,
                        placement: placement,
                        worldCenter: center,
                        bearingRadians: bearing,
                        nearestPortalDistance: nearestExisting,
                        nearestReservedDistance: nearestReserved,
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
                  nearestExistingM: \(chosen.nearestPortalDistance)
                  nearestReservedM: \(chosen.nearestReservedDistance)
                  bearingGapRad: \(chosen.nearestBearingGap)
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
