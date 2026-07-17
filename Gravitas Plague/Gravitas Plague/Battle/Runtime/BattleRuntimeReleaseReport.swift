import Foundation

struct BattleRuntimeMemorySnapshot: Sendable, Equatable {
    let label: String
    let physicalFootprintMB: UInt64
    let residentSizeMB: UInt64
    let availableProcessMemoryMB: UInt64

    static func capture(label: String) -> Self {
        let value = TuringMemoryBudgetProbe.log(label: label)
        return Self(
            label: label,
            physicalFootprintMB: value.physicalFootprintMB,
            residentSizeMB: value.residentSizeMB,
            availableProcessMemoryMB: value.availableProcessMemoryMB
        )
    }
}

struct BattleRuntimeReleaseReport: Sendable, Equatable {
    let battleInstanceID: UUID
    let enemyResults: [BattleEnemyRuntimeReleaseResult]
    let fullPortalReleased: Bool
    let musicStillPlaying: Bool
    let before: BattleRuntimeMemorySnapshot
    let after: BattleRuntimeMemorySnapshot

    var allHeavyEnemyRuntimesReleased: Bool {
        enemyResults.allSatisfy(\.heavyRuntimeReleased)
    }

    var allEnemyControllersReleased: Bool {
        enemyResults.allSatisfy(\.weakControllerReleased)
    }

    var formattedLog: String {
        """
        [BattleRuntimeCleanup] completed
          battleInstanceID: \(battleInstanceID.uuidString)
          enemyCount: \(enemyResults.count)
          allHeavyEnemyRuntimesReleased: \(allHeavyEnemyRuntimesReleased)
          allEnemyControllersReleased: \(allEnemyControllersReleased)
          fullPortalReleased: \(fullPortalReleased)
          musicStillPlaying: \(musicStillPlaying)
          physFootprintBeforeMB: \(before.physicalFootprintMB)
          physFootprintAfterMB: \(after.physicalFootprintMB)
          residentBeforeMB: \(before.residentSizeMB)
          residentAfterMB: \(after.residentSizeMB)
        """
    }
}

struct BattleRuntimeReleasedEvent: Sendable, Equatable {
    let eventID: UUID
    let battleInstanceID: UUID
    let releaseReport: BattleRuntimeReleaseReport
}
