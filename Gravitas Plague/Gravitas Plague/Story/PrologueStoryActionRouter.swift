import Foundation

@MainActor
final class PrologueStoryActionRouter {
    private let battle01: Battle01Coordinator
    private var handledEventIDs = Set<UUID>()
    private var battle01Triggered = false

    init(battle01: Battle01Coordinator) {
        self.battle01 = battle01
    }

    func scriptPointCompleted(_ event: TuringScriptPointCompletionEvent) async throws {
        guard event.scriptPointID == "prologue.scriptPoint03",
              handledEventIDs.insert(event.eventID).inserted,
              battle01Triggered == false else {
            return
        }
        battle01Triggered = true
        let battleInstanceID = UUID()
        do {
            let lease = try await TuringEpisodeFlowController.shared
                .transferActiveInteractionToBattle(
                    battleInstanceID: battleInstanceID,
                    reason: "scriptPoint03ToBattle01"
                )
            battle01.start(
                trigger: .scriptPointCompleted(event),
                instanceID: battleInstanceID,
                interactionLease: lease
            )
        } catch {
            battle01Triggered = false
            throw error
        }
    }

    func startBattle01FromContinuation(
        sourceEventID: UUID,
        storyTransitionLease: StoryInteractionLease
    ) async throws {
        guard battle01Triggered == false else { return }
        battle01Triggered = true
        let battleInstanceID = UUID()
        do {
            let lease = try await StoryInteractionArbiter.shared
                .transferStoryTransitionToBattle(
                    storyTransitionLease: storyTransitionLease,
                    battleInstanceID: battleInstanceID,
                    reason: "continuationRestore"
                )
            battle01.start(
                trigger: .continuationRestore(
                    snapshotSourceEventID: sourceEventID
                ),
                instanceID: battleInstanceID,
                interactionLease: lease
            )
        } catch {
            battle01Triggered = false
            throw error
        }
    }

    func reset(reason: String) {
        handledEventIDs.removeAll(keepingCapacity: false)
        battle01Triggered = false
        print("[Battle01] Prologue action router reset reason=\(reason)")
    }
}
