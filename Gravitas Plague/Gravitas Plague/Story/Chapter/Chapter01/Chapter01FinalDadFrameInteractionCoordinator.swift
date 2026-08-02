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
        transitionLease: StoryInteractionLease
    ) async throws {
        guard snapshot.checkpoint == .finalDadFramePending ||
                snapshot.checkpoint == .complete else {
            throw Chapter01Error.invalidFinalDadFrameTransition
        }
        try await arbiter.requireCurrent(transitionLease)
        try await install(
            checkpoint: snapshot.checkpoint,
            transitionLease: transitionLease,
            reason: "chapter01FinalDadFrameRestored"
        )
    }

    private func install(
        checkpoint: Chapter01Checkpoint,
        transitionLease: StoryInteractionLease,
        reason: String
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
        try await arbiter.setStableInteractionPolicy(
            .chapter01FinalDadFrameOnly,
            storyTransitionLease: transitionLease,
            reason: reason
        )
        let releasedSnapshot = await arbiter.releaseAndCurrentSnapshot(
            transitionLease,
            reason: "\(reason).ready"
        )
        let expectedPresentation: StoryDadFramePresentation =
            finalState == .play ? .play : .microphone
        let expectedCapability: StoryInteractionCapability =
            finalState == .play ? .dadFramePlay : .dadFrameMicrophone
        guard releasedSnapshot.exclusiveOwner == nil,
              releasedSnapshot.doorState == .closedUnloaded,
              releasedSnapshot.dadFramePresentation == expectedPresentation,
              releasedSnapshot.capabilities == [expectedCapability] else {
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
        dadFrame.applyInteractionSnapshot(releasedSnapshot)
        print(
            "[Chapter01FinalDadFrame] stable policy installed " +
                "policy=chapter01FinalDadFrameOnly " +
                "dadFrame=\(finalState.rawValue) " +
                "walkie=hidden hamReceiver=hidden crankRadio=hidden door=hidden " +
                "synchronousPresentationApplied=true"
        )
    }
}
