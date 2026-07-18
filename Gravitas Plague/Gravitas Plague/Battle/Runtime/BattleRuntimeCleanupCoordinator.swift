import Foundation

@MainActor
final class BattleRuntimeCleanupCoordinator {
    enum CleanupError: LocalizedError {
        case incomplete(BattleRuntimeReleaseReport)

        var errorDescription: String? {
            switch self {
            case .incomplete:
                return "Battle runtime release did not clear every enemy and portal allocation."
            }
        }
    }

    private let registry: BattleEnemyRuntimeRegistry
    private let corpsePresenter: BattleCorpsePresentationController
    private var releasedResultsByBattleID:
        [UUID: [UUID: BattleEnemyRuntimeReleaseResult]] = [:]

    init(
        registry: BattleEnemyRuntimeRegistry,
        corpsePresenter: BattleCorpsePresentationController
    ) {
        self.registry = registry
        self.corpsePresenter = corpsePresenter
    }

    func releaseEnemy(
        battleInstanceID: UUID,
        enemyID: UUID,
        reason: BattleEnemyReleaseReason,
        retentionPolicy: BattleEnemyRetentionPolicy
    ) async throws -> BattleEnemyRuntimeReleaseResult {
        if let existing = releasedResultsByBattleID[battleInstanceID]?[enemyID] {
            return existing
        }
        guard let lease = registry.take(
            battleInstanceID: battleInstanceID,
            enemyID: enemyID
        ) else {
            throw CleanupError.incomplete(
                emptyFailureReport(battleInstanceID: battleInstanceID)
            )
        }

        print("""
        [BattleRuntimeCleanup] enemy release started
          battleInstanceID: \(battleInstanceID.uuidString)
          enemyID: \(enemyID.uuidString)
          reason: \(reason.rawValue)
        """)
        let result = try await lease.release(
            reason: reason,
            retentionPolicy: retentionPolicy,
            corpsePresenter: corpsePresenter
        )
        releasedResultsByBattleID[
            battleInstanceID,
            default: [:]
        ][enemyID] = result
        print("""
        [BattleRuntimeCleanup] enemy heavy fields cleared
          battleInstanceID: \(battleInstanceID.uuidString)
          enemyID: \(enemyID.uuidString)
          preparedClipsReleased: \(result.releasedPreparedClipCount)
          collisionReleased: \(result.releasedCollisionCount)
          characterAudioReleased: \(result.releasedAudioControllerCount)
          activeEnemyLeaseCount: \(registry.activeEnemyCount(battleInstanceID: battleInstanceID))
        """)
        return result
    }

    func releaseBattle(
        battleInstanceID: UUID,
        reason: BattleEnemyReleaseReason,
        retentionPolicy: BattleEnemyRetentionPolicy,
        fullPortalReleased: Bool,
        musicStillPlaying: Bool,
        beforeSnapshot: BattleRuntimeMemorySnapshot? = nil
    ) async throws -> BattleRuntimeReleaseReport {
        let before = beforeSnapshot ?? BattleRuntimeMemorySnapshot.capture(
            label: "beforeBattleRuntimeRelease"
        )
        let leases = registry.drain(battleInstanceID: battleInstanceID)
        let previouslyReleased = releasedResultsByBattleID.removeValue(
            forKey: battleInstanceID
        ) ?? [:]
        var results = Array(previouslyReleased.values)
        results.reserveCapacity(results.count + leases.count)

        for lease in leases {
            let result = try await lease.release(
                reason: reason,
                retentionPolicy: retentionPolicy,
                corpsePresenter: corpsePresenter
            )
            results.append(result)
        }

        let after = BattleRuntimeMemorySnapshot.capture(label: "afterBattleRuntimeRelease")
        let report = BattleRuntimeReleaseReport(
            battleInstanceID: battleInstanceID,
            enemyResults: results,
            fullPortalReleased: fullPortalReleased,
            musicStillPlaying: musicStillPlaying,
            before: before,
            after: after
        )
        let releasedExpectedEnemy = reason != .neutralized || results.isEmpty == false
        guard releasedExpectedEnemy,
              report.allHeavyEnemyRuntimesReleased,
              report.allEnemyControllersReleased,
              report.fullPortalReleased,
              registry.activeEnemyCount(battleInstanceID: battleInstanceID) == 0 else {
            throw CleanupError.incomplete(report)
        }
        print(report.formattedLog)
        return report
    }

    var hasActiveEnemyRuntime: Bool {
        registry.totalActiveEnemyCount > 0
    }

    private func emptyFailureReport(
        battleInstanceID: UUID
    ) -> BattleRuntimeReleaseReport {
        let snapshot = BattleRuntimeMemorySnapshot.capture(
            label: "battleRuntimeMissingEnemyLease"
        )
        return BattleRuntimeReleaseReport(
            battleInstanceID: battleInstanceID,
            enemyResults: [],
            fullPortalReleased: false,
            musicStillPlaying: false,
            before: snapshot,
            after: snapshot
        )
    }
}
