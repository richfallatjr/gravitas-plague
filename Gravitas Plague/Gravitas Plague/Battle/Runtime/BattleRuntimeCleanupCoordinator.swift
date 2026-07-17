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

    init(
        registry: BattleEnemyRuntimeRegistry,
        corpsePresenter: BattleCorpsePresentationController
    ) {
        self.registry = registry
        self.corpsePresenter = corpsePresenter
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
        var results: [BattleEnemyRuntimeReleaseResult] = []
        results.reserveCapacity(leases.count)

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
}
