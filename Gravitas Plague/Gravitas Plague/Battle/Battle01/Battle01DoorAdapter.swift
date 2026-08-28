import Foundation
import RealityKit

enum TuringStoryDoorBattleState: String, Sendable {
    case closed
    case opening
    case open
    case closing
}

struct TuringStoryDoorBattlePortalContext {
    let doorRoot: Entity
    let portalWorldRoot: Entity
    let portalPlane: Entity
    let zombieA1: Entity
    let zombieA2: Entity
    let zombieA3: Entity
    let doorAudioEmitter: Entity
}

@MainActor
protocol TuringStoryDoorBattleControlling: AnyObject {
    var battleDoorState: TuringStoryDoorBattleState { get }
    func setBattleInteractionLocked(
        _ locked: Bool,
        ownerID: UUID,
        reason: String
    )
    func observeBattleDoorOpening(
        ownerID: UUID,
        handler: @escaping @MainActor (
            TuringStoryDoorBattleOpeningBeganEvent
        ) -> Void
    ) -> TuringStoryDoorBattleOpeningObservation
    func acquireBattlePortal(ownerID: UUID, reason: String) async throws
    func releaseBattlePortal(ownerID: UUID, reason: String)
    func openForBattle(ownerID: UUID, reason: String) async throws
    func closeForBattleAndUnloadPortal(ownerID: UUID, reason: String) async throws
    func battlePortalContext() throws -> TuringStoryDoorBattlePortalContext
    var battlePortalFullExteriorResident: Bool { get }
}

enum StoryBattlePortalExitAutoClosePolicy {
    // Flip this single switch to restore the previous battle-long open portal.
    static let isEnabled = true
    static let delaySeconds: TimeInterval = 5
}

@MainActor
final class StoryBattlePortalExitCleanupController {
    private let door: any TuringStoryDoorBattleControlling
    private let clock: any BattleClock
    private var scheduledTask: Task<Void, Never>?
    private var scheduledRequestID: UUID?

    init(
        door: any TuringStoryDoorBattleControlling,
        clock: any BattleClock
    ) {
        self.door = door
        self.clock = clock
    }

    func scheduleAfterPortalExit(ownerID: UUID, reason: String) {
        scheduledTask?.cancel()
        scheduledTask = nil
        scheduledRequestID = nil

        guard StoryBattlePortalExitAutoClosePolicy.isEnabled else {
            print(
                "[StoryBattlePortalExit] auto-close disabled " +
                    "ownerID=\(ownerID.uuidString) reason=\(reason)"
            )
            return
        }

        let requestID = UUID()
        scheduledRequestID = requestID
        scheduledTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(
                    for: .seconds(
                        StoryBattlePortalExitAutoClosePolicy.delaySeconds
                    )
                )
                try Task.checkCancellation()
                guard self.scheduledRequestID == requestID else { return }
                try await self.closeAndUnloadIfNeeded(
                    ownerID: ownerID,
                    reason: "portalExitAutoClose.\(reason)"
                )
                print(
                    "[StoryBattlePortalExit] auto-close completed " +
                        "ownerID=\(ownerID.uuidString) " +
                        "fullExteriorResident=" +
                        "\(self.door.battlePortalFullExteriorResident)"
                )
            } catch is CancellationError {
                // A normal battle teardown takes over from this task.
            } catch {
                print(
                    "[StoryBattlePortalExit] auto-close failed " +
                        "ownerID=\(ownerID.uuidString) " +
                        "error=\(error.localizedDescription)"
                )
            }
            self.finishScheduledRequest(requestID)
        }
        print(
            "[StoryBattlePortalExit] auto-close scheduled " +
                "ownerID=\(ownerID.uuidString) " +
                "delaySeconds=" +
                "\(StoryBattlePortalExitAutoClosePolicy.delaySeconds) " +
                "reason=\(reason)"
        )
    }

    func closeAndUnloadNowIfNeeded(
        ownerID: UUID,
        reason: String
    ) async throws {
        let pendingTask = scheduledTask
        scheduledTask = nil
        scheduledRequestID = nil
        pendingTask?.cancel()
        if let pendingTask {
            await pendingTask.value
        }
        try await closeAndUnloadIfNeeded(
            ownerID: ownerID,
            reason: reason
        )
    }

    private func closeAndUnloadIfNeeded(
        ownerID: UUID,
        reason: String
    ) async throws {
        guard door.battleDoorState != .closed ||
                door.battlePortalFullExteriorResident else {
            print(
                "[StoryBattlePortalExit] close skipped; already unloaded " +
                    "ownerID=\(ownerID.uuidString) reason=\(reason)"
            )
            return
        }
        try await door.closeForBattleAndUnloadPortal(
            ownerID: ownerID,
            reason: reason
        )
    }

    private func finishScheduledRequest(_ requestID: UUID) {
        guard scheduledRequestID == requestID else { return }
        scheduledTask = nil
        scheduledRequestID = nil
    }
}

extension TuringStoryDoorBundleController: TuringStoryDoorBattleControlling {}
