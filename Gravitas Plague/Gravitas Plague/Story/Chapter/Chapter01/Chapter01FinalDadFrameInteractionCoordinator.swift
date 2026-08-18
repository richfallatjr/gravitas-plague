import Foundation

@MainActor
final class Chapter01FinalDadFrameInteractionCoordinator {
    private let progress: Chapter01ProgressStore
    private let arbiter: StoryInteractionArbiter
    private let gate: TuringFlowInteractionGateController
    private unowned let dadFrame: TuringStoryDadFrameInteractionController

    init(
        dadFrame: TuringStoryDadFrameInteractionController,
        progress: Chapter01ProgressStore = .shared,
        arbiter: StoryInteractionArbiter = .shared,
        gate: TuringFlowInteractionGateController? = nil
    ) {
        self.dadFrame = dadFrame
        self.progress = progress
        self.arbiter = arbiter
        self.gate = gate ?? .shared
    }

    func unlockAfterBattle(
        event: Chapter01DadFinalBattleReleasedEvent
    ) async throws {
        guard event.isSafeForFinalDadFrame else {
            throw Chapter01Error.dadFinalBattleReleaseBoundaryFailed
        }
        try await arbiter.requireCurrent(event.battleLease)
        let snapshot = try await progress.commitFinalDadFramePending(
            sourceEventID: event.eventID
        )
        let transitionLease = try await arbiter
            .transferBattleToStoryTransition(
                battleLease: event.battleLease,
                transitionID: UUID(),
                reason: "chapter01DadBattleReleased"
            )
        try await install(
            checkpoint: snapshot.checkpoint,
            transitionLease: transitionLease,
            reason: "chapter01FinalDadFramePending"
        )
        print(
            "[Chapter01FinalDadFrame] ownership transferred " +
                "from=battle to=storyTransition ownerlessSnapshotPublished=false"
        )
    }

    func restore(
        snapshot: Chapter01ProgressSnapshot,
        transitionLease: StoryInteractionLease,
        releaseWhenReady: Bool = true
    ) async throws {
        guard snapshot.checkpoint == .finalDadFramePending ||
                snapshot.checkpoint == .complete else {
            throw Chapter01Error.invalidFinalDadFrameTransition
        }
        try await arbiter.requireCurrent(transitionLease)
        try await install(
            checkpoint: snapshot.checkpoint,
            transitionLease: transitionLease,
            reason: "chapter01FinalDadFrameRestored",
            releaseWhenReady: releaseWhenReady
        )
    }

    private func install(
        checkpoint: Chapter01Checkpoint,
        transitionLease: StoryInteractionLease,
        reason: String,
        releaseWhenReady: Bool = true
    ) async throws {
        let finalBinding = TuringStorySurfaceFlowBinding
            .chapter01DadEulogyScript03
        let finalState: TuringFlowInteractionGateController.State
        switch checkpoint {
        case .finalDadFramePending, .complete:
            await TuringConversationInputStore.shared.clear(
                key: finalBinding.conversationKey
            )
            finalState = .play
        default:
            throw Chapter01Error.invalidFinalDadFrameTransition
        }

        dadFrame.stageBinding(finalBinding, reason: reason)
        await gate.applyStableStatesAtomically(
            [
                .dadFrame: finalState,
                .walkie: .closed,
                .hamReceiver: .closed,
                .crankRadio: .closed
            ],
            reason: reason
        )
        StoryModeActionCoordinator.shared.activate(
            .init(
                episodeID: .chapter01,
                rootScriptPointID: finalBinding.rootScriptPointID,
                durableBoundaryID:
                    "chapter01.finalDadFrame.\(checkpoint.rawValue)",
                sourceEventID: UUID()
            )
        )
        try await arbiter.setStableInteractionPolicy(
            .chapter01FinalDadFrameOnly,
            storyTransitionLease: transitionLease,
            reason: reason
        )
        let releasedSnapshot: StoryInteractionSnapshot
        if releaseWhenReady {
            releasedSnapshot = await arbiter.releaseAndCurrentSnapshot(
                transitionLease,
                reason: "\(reason).ready"
            )
        } else {
            releasedSnapshot = await arbiter.currentSnapshot()
        }
        let expectedPresentation: StoryDadFramePresentation = .hidden
        let expectedCapability: StoryInteractionCapability? = nil
        let ownerIsValid = releaseWhenReady
            ? releasedSnapshot.exclusiveOwner == nil
            : releasedSnapshot.exclusiveOwner == transitionLease.owner
        guard ownerIsValid,
              releasedSnapshot.doorState == .closedUnloaded,
              (releaseWhenReady
                ? releasedSnapshot.dadFramePresentation == expectedPresentation
                : releasedSnapshot.dadFramePresentation == .hidden),
              (releaseWhenReady
                ? (expectedCapability.map {
                    releasedSnapshot.capabilities == [$0]
                  } ?? releasedSnapshot.capabilities.isEmpty)
                : releasedSnapshot.capabilities.isEmpty) else {
            print(
                "[Chapter01FinalDadFrame] ERROR stable presentation rejected " +
                    "owner=\(releasedSnapshot.exclusiveOwner?.logValue ?? "none") " +
                    "doorState=\(releasedSnapshot.doorState.rawValue) " +
                    "dadFrame=\(releasedSnapshot.dadFramePresentation.rawValue) " +
                    "capabilities=\(releasedSnapshot.capabilities.map(\.rawValue).sorted())"
            )
            throw Chapter01Error.finalDadFramePresentationFailed
        }

        // The stream remains the normal presentation path. Applying the exact
        // authorized release snapshot here prevents a suspended observer from
        // dropping the first stable post-battle action.
        if releaseWhenReady {
            dadFrame.applyInteractionSnapshot(releasedSnapshot)
        }
        print(
            "[Chapter01FinalDadFrame] stable policy installed " +
                "policy=chapter01FinalDadFrameOnly " +
                "dadFrame=\(finalState.rawValue) " +
                "walkie=hidden hamReceiver=hidden crankRadio=hidden door=hidden " +
                "synchronousPresentationApplied=true"
        )
    }
}
