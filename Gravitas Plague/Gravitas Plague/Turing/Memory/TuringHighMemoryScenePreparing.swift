import Foundation

protocol TuringHighMemoryScenePreparing: AnyObject, Sendable {
    func prepareForTuringHighMemoryRun(runID: String) async throws
    func acquireAutomaticTuringInteractionLease(
        runID: String,
        source: String
    ) async throws -> StoryInteractionLease
}

@MainActor
final class StoryTuringHighMemoryPreflightAdapter:
    TuringHighMemoryScenePreparing
{
    private weak var door:
        TuringStoryDoorBundleController?
    private weak var battleRuntime:
        Battle01Coordinator?

    init(
        door: TuringStoryDoorBundleController,
        battleRuntime: Battle01Coordinator
    ) {
        self.door = door
        self.battleRuntime = battleRuntime
    }

    nonisolated func prepareForTuringHighMemoryRun(
        runID: String
    ) async throws {
        try await prepareOnMainActor(runID: runID)
    }

    nonisolated func acquireAutomaticTuringInteractionLease(
        runID: String,
        source: String
    ) async throws -> StoryInteractionLease {
        try await acquireAutomaticLeaseOnMainActor(
            runID: runID,
            source: source
        )
    }

    private func prepareOnMainActor(runID: String) async throws {
        print("""
        [TuringHighMemoryPreflight] Story boundary inspected
          runID: \(runID)
          battleRuntimeActive: \(battleRuntime?.hasActiveBattleRuntime ?? false)
          doorState: \(String(describing: door?.doorPortalLifecycleState))
          fullExteriorLoaded: \(door?.battlePortalFullExteriorResident ?? false)
        """)
        if let battleRuntime,
           battleRuntime.hasActiveBattleRuntime {
            print("""
            [TuringHighMemoryPreflight] waiting for battle runtime release
              runID: \(runID)
            """)
            await battleRuntime.waitUntilRuntimeReleased()
        }

        guard let door else {
            return
        }
        try await door.ensureClosedAndUnloadedForTuring(
            reason: "turingRun.\(runID)"
        )
    }

    private func acquireAutomaticLeaseOnMainActor(
        runID: String,
        source: String
    ) async throws -> StoryInteractionLease {
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        if case .battle = snapshot.exclusiveOwner,
           let battleRuntime {
            await battleRuntime.waitUntilRuntimeReleased()
        }

        let refreshed = await StoryInteractionArbiter.shared.currentSnapshot()
        if case .doorPortal = refreshed.exclusiveOwner {
            guard let door else {
                throw StoryInteractionClaimError.invalidTransfer
            }
            return try await door.closeUnloadAndTransferToTuring(
                runID: runID,
                reason: source
            )
        }

        return try await StoryInteractionArbiter.shared.claimAutomaticTuring(
            runID: runID,
            source: source
        )
    }
}
