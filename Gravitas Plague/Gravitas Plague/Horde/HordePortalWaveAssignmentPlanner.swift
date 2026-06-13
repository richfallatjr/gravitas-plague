import Foundation
import simd

@MainActor
final class HordePortalWaveAssignmentPlanner {
    private let portalManager: HordePortalManager

    init(
        portalManager: HordePortalManager
    ) {
        self.portalManager = portalManager
    }

    func buildAssignmentsForWave(
        wave: Int,
        spawnRequests: [(id: UUID, archetype: PlagueCharacterArchetype)],
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) async -> [HordePortalAssignment] {
        var assignments: [HordePortalAssignment] = []
        var reservedPortalIDs = Set<UUID>()

        print(
            """
            [HordePortalAssignment] planning wave
              wave: \(wave)
              requestedEnemies: \(spawnRequests.count)
              existingPortals: \(portalManager.portals.count)
            """
        )

        for index in spawnRequests.indices {
            let request = spawnRequests[index]
            let portalAndKind = await portalForEnemy(
                wave: wave,
                spawnIndex: index,
                reservedPortalIDs: reservedPortalIDs,
                playerPosition: playerPosition,
                playerForward: playerForward
            )

            guard let portalAndKind else {
                print(
                    """
                    [HordePortalAssignment] ERROR no portal available for enemy
                      wave: \(wave)
                      index: \(index)
                      enemyID: \(request.id)
                      archetype: \(request.archetype.rawValue)
                    """
                )
                continue
            }

            let side = portalManager.nextEntranceSide(
                portalID: portalAndKind.portal.id
            )

            reservedPortalIDs.insert(portalAndKind.portal.id)

            assignments.append(
                HordePortalAssignment(
                    enemyID: request.id,
                    archetype: request.archetype,
                    portalID: portalAndKind.portal.id,
                    side: side,
                    assignmentKind: portalAndKind.kind
                )
            )

            print(
                """
                [HordePortalAssignment] assigned
                  wave: \(wave)
                  index: \(index)
                  enemyID: \(request.id)
                  archetype: \(request.archetype.rawValue)
                  portalID: \(portalAndKind.portal.id)
                  side: \(side.rawValue)
                  kind: \(portalAndKind.kind.rawValue)
                  reservedThisWave: \(reservedPortalIDs.count)
                """
            )
        }

        logDuplicateAssignmentsIfNeeded(
            wave: wave,
            assignments: assignments
        )

        return assignments
    }

    private func portalForEnemy(
        wave: Int,
        spawnIndex: Int,
        reservedPortalIDs: Set<UUID>,
        playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) async -> (portal: HordePortal, kind: HordePortalAssignment.AssignmentKind)? {
        if let existing = portalManager.bestUnreservedPortal(
            excluding: reservedPortalIDs,
            playerPosition: playerPosition
        ) {
            return (
                existing,
                .uniqueExistingPortal
            )
        }

        if let newPortal = await portalManager.createPortalForWave(
            wave: wave,
            spawnIndex: spawnIndex,
            playerPosition: playerPosition,
            playerForward: playerForward,
            excludingPortalIDs: reservedPortalIDs
        ) {
            return (
                newPortal,
                .uniqueNewPortal
            )
        }

        if let reuse = portalManager.leastUsedPortal() {
            return (
                reuse,
                .forcedReuseNoCapacity
            )
        }

        return nil
    }

    private func logDuplicateAssignmentsIfNeeded(
        wave: Int,
        assignments: [HordePortalAssignment]
    ) {
        let grouped = Dictionary(
            grouping: assignments,
            by: \.portalID
        )
        let duplicates = grouped.filter {
            $0.value.count > 1
        }

        guard !duplicates.isEmpty else {
            return
        }

        let allAreForced = duplicates.values
            .flatMap { $0 }
            .allSatisfy {
                $0.assignmentKind == .forcedReuseNoCapacity
            }

        if allAreForced {
            print(
                """
                [HordePortalAssignment] WARNING duplicate portal assignments unavoidable
                  wave: \(wave)
                  duplicates: \(duplicates.count)
                  reason: no_capacity_or_no_valid_wall_slots
                """
            )
        } else {
            let description = duplicates.map { portalID, assignments in
                "\(portalID):\(assignments.count)"
            }
            .joined(separator: ", ")

            print(
                """
                [HordePortalAssignment] ERROR duplicate portal assignment despite non-forced capacity
                  duplicates: \(description)
                  action: investigate_assignment_planner
                """
            )
        }
    }
}
