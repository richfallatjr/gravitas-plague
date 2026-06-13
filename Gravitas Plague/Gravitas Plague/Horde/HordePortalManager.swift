import Foundation
import RealityKit
import simd
import UIKit

@MainActor
final class HordePortalManager {
    private(set) var portals: [UUID: HordePortal] = [:]
    private var portalOrder: [UUID] = []

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

        print("[HordePortal] reset")
    }

    func createPortalForWave(
        wave: Int,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) async -> HordePortal? {
        guard let sceneRoot,
              let wallManager else {
            print("[HordePortal] ERROR manager not installed")
            return nil
        }

        guard let candidate = choosePortalPlacement(
            wave: wave,
            playerPosition: playerPosition,
            playerForward: playerForward
        ) else {
            print("[HordePortal] ERROR no placement candidate")
            return nil
        }

        let wall = candidate.wall
        let placement = candidate.placement

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

        let rim = DimensionalTearPortalRimFactory.makeRim(
            width: placement.width,
            height: placement.height,
            seed: UInt64(wave) ^ UInt64(portalOrder.count)
        )

        let portalPlane = makeHordePortalPlane(
            width: placement.width * 0.84,
            height: placement.height * 0.86,
            targetWorld: portalWorld
        )

        portalPlane.position.z = -0.006

        root.addChild(rim)
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

        let portal = HordePortal(
            id: UUID(),
            waveCreated: wave,
            wallID: wall.id,
            placement: placement,
            root: root,
            portalWorldRoot: portalWorld,
            portalPlane: portalPlane,
            resolvedFloorWorldY: placement.floorWorldY,
            worldCenter: worldCenter,
            bearingFromPlayerRadians: candidate.bearingRadians,
            entranceCount: 0
        )

        portals[portal.id] = portal
        portalOrder.append(portal.id)

        print(
            """
            [HordePortal] portal created
              wave: \(wave)
              portalID: \(portal.id)
              wallID: \(wall.id)
              localX: \(placement.localX)
              localY: \(placement.localY)
              width: \(placement.width)
              height: \(placement.height)
              nearestDistanceM: \(candidate.nearestPortalDistance)
              nearestBearingGapRad: \(candidate.nearestBearingGap)
              backdrop: hellscape_01.exr
              persists: true
            """
        )

        return portal
    }

    func randomPortalForSpawn(
        preferNewest: Bool = false
    ) -> HordePortal? {
        if preferNewest,
           let lastID = portalOrder.last,
           let portal = portals[lastID] {
            return portal
        }

        let sorted = portals.values.sorted { lhs, rhs in
            if lhs.entranceCount != rhs.entranceCount {
                return lhs.entranceCount < rhs.entranceCount
            }

            return Bool.random()
        }

        return sorted.prefix(3).randomElement()
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
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> HordePortalPlacementCandidate? {
        guard let wallManager else {
            return nil
        }
        _ = playerForward

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

            for _ in 0..<HordePortalPlacementTuning.candidateCountPerWall {
                var placement = DoorPlacement.defaultForWall(wall)
                placement.floorLocked = true
                placement.confirmed = true
                placement.contentProviderID = HordeHellscapePortalContentProvider.providerID
                placement.width = Float.random(in: 0.78...1.08)
                placement.height = Float.random(in: 1.85...2.18)

                let maxX = max(
                    0,
                    wall.width * 0.5 - placement.width * 0.5 - 0.1
                )

                placement.localX = maxX > 0
                    ? Float.random(in: -maxX...maxX)
                    : 0

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

                let nearestDistance = nearestExistingPortalDistance(
                    to: center
                )

                let bearingGap = nearestExistingPortalBearingGap(
                    bearing
                )

                let spacingScore = min(
                    1,
                    nearestDistance / HordePortalPlacementTuning.preferredSpacingMeters
                )

                let angularScore = min(
                    1,
                    bearingGap / (.pi / 3)
                )

                let wallReusePenalty: Float = portals.values.contains { $0.wallID == wall.id }
                    ? 0.25
                    : 0.0

                let score =
                    spacingScore * 2.0 +
                    angularScore * 2.0 +
                    Float.random(in: 0...0.35) -
                    wallReusePenalty

                candidates.append(
                    HordePortalPlacementCandidate(
                        wall: wall,
                        placement: placement,
                        worldCenter: center,
                        bearingRadians: bearing,
                        nearestPortalDistance: nearestDistance,
                        nearestBearingGap: bearingGap,
                        score: score
                    )
                )
            }
        }

        let valid = candidates.filter {
            $0.nearestPortalDistance >= HordePortalPlacementTuning.minSpacingMeters
        }

        let chosen = (valid.isEmpty ? candidates : valid)
            .max { lhs, rhs in
                lhs.score < rhs.score
            }

        if let chosen {
            print(
                """
                [HordePortalPlacement] candidate chosen
                  wave: \(wave)
                  wallID: \(chosen.wall.id)
                  localX: \(chosen.placement.localX)
                  localY: \(chosen.placement.localY)
                  nearestDistanceM: \(chosen.nearestPortalDistance)
                  nearestBearingGapRad: \(chosen.nearestBearingGap)
                  score: \(chosen.score)
                  validSpacing: \(!valid.isEmpty)
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

    private func makeHordePortalPlane(
        width: Float,
        height: Float,
        targetWorld: Entity
    ) -> ModelEntity {
        let portal = ModelEntity(
            mesh: .generatePlane(
                width: width,
                height: height
            ),
            materials: [PortalMaterial()]
        )

        portal.name = "HordePortalPlane"
        portal.components.set(
            PortalComponent(
                target: targetWorld
            )
        )

        return portal
    }
}
