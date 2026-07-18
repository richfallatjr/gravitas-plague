import Foundation

@MainActor
final class BattleEnemyRuntimeLease {
    let identity: BattleEnemyRuntimeIdentity

    private var controller: (any BattleEnemyRuntimeReleasable)?
    private var portalMirror: StoryPortalEnemyRenderMirrorAdapter?
    private var releasedResult: BattleEnemyRuntimeReleaseResult?

    init(
        identity: BattleEnemyRuntimeIdentity,
        controller: any BattleEnemyRuntimeReleasable,
        portalMirror: StoryPortalEnemyRenderMirrorAdapter?
    ) {
        self.identity = identity
        self.controller = controller
        self.portalMirror = portalMirror
    }

    func release(
        reason: BattleEnemyReleaseReason,
        retentionPolicy: BattleEnemyRetentionPolicy,
        corpsePresenter: BattleCorpsePresentationController
    ) async throws -> BattleEnemyRuntimeReleaseResult {
        if let releasedResult { return releasedResult }

        portalMirror?.removeAndRelease(reason: reason.rawValue)
        portalMirror = nil

        guard controller != nil else {
            let result = BattleEnemyRuntimeReleaseResult(
                identity: identity,
                heavyRuntimeReleased: true,
                visibleRuntimeRemoved: true,
                staticCorpseInstalled: false,
                releasedPreparedClipCount: 0,
                releasedCollisionCount: 0,
                releasedAudioControllerCount: 0,
                weakControllerReleased: true,
                notes: ["controller already absent"]
            )
            releasedResult = result
            return result
        }

        weak var weakController = controller as AnyObject?
        let result = try await releaseOwnedController(
            reason: reason,
            retentionPolicy: retentionPolicy,
            corpsePresenter: corpsePresenter
        )
        controller = nil
        for _ in 0..<3 where weakController != nil {
            await Task.yield()
        }
        let finalResult = result.recordingControllerRelease(
            weakController == nil
        )
        print("""
        [BattleRuntimeCleanup] enemy lease released
          battleInstanceID: \(identity.battleInstanceID.uuidString)
          enemyID: \(identity.enemyID.uuidString)
          heavyRuntimeReleased: \(finalResult.heavyRuntimeReleased)
          controllerDeallocated: \(finalResult.weakControllerReleased)
        """)
        releasedResult = finalResult
        return finalResult
    }

    private func releaseOwnedController(
        reason: BattleEnemyReleaseReason,
        retentionPolicy: BattleEnemyRetentionPolicy,
        corpsePresenter: BattleCorpsePresentationController
    ) async throws -> BattleEnemyRuntimeReleaseResult {
        guard let controller else {
            preconditionFailure("Battle enemy controller disappeared before release.")
        }
        return try await controller.releaseBattleRuntime(
            reason: reason,
            retentionPolicy: retentionPolicy,
            corpsePresenter: corpsePresenter
        )
    }
}

@MainActor
final class BattleEnemyRuntimeRegistry {
    enum RegistryError: LocalizedError {
        case duplicate(BattleEnemyRuntimeIdentity)

        var errorDescription: String? {
            switch self {
            case .duplicate(let identity):
                return "Duplicate battle enemy runtime \(identity.enemyID)."
            }
        }
    }

    private var leasesByBattleID: [UUID: [UUID: BattleEnemyRuntimeLease]] = [:]

    func register(_ lease: BattleEnemyRuntimeLease) throws {
        let identity = lease.identity
        guard leasesByBattleID[identity.battleInstanceID]?[identity.enemyID] == nil else {
            throw RegistryError.duplicate(identity)
        }
        leasesByBattleID[identity.battleInstanceID, default: [:]][identity.enemyID] = lease
        print("[BattleRuntimeRegistry] registered battleInstanceID=\(identity.battleInstanceID) enemyID=\(identity.enemyID)")
    }

    func drain(battleInstanceID: UUID) -> [BattleEnemyRuntimeLease] {
        guard let leases = leasesByBattleID.removeValue(forKey: battleInstanceID) else {
            return []
        }
        return leases.values.sorted {
            $0.identity.enemyID.uuidString < $1.identity.enemyID.uuidString
        }
    }

    func take(
        battleInstanceID: UUID,
        enemyID: UUID
    ) -> BattleEnemyRuntimeLease? {
        guard var leases = leasesByBattleID[battleInstanceID],
              let lease = leases.removeValue(forKey: enemyID) else {
            return nil
        }
        if leases.isEmpty {
            leasesByBattleID.removeValue(forKey: battleInstanceID)
        } else {
            leasesByBattleID[battleInstanceID] = leases
        }
        return lease
    }

    func drainAll() -> [BattleEnemyRuntimeLease] {
        let leases = leasesByBattleID.values.flatMap { Array($0.values) }
        leasesByBattleID.removeAll(keepingCapacity: false)
        return leases
    }

    func activeEnemyCount(battleInstanceID: UUID) -> Int {
        leasesByBattleID[battleInstanceID]?.count ?? 0
    }

    var totalActiveEnemyCount: Int {
        leasesByBattleID.values.reduce(0) { $0 + $1.count }
    }
}
