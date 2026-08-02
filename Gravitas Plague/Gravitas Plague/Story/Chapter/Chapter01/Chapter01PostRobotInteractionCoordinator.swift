import Foundation

@MainActor
final class Chapter01PostRobotInteractionCoordinator {
    private let gate: TuringFlowInteractionGateController
    private let arbiter: StoryInteractionArbiter
    private let progress: Chapter01ProgressStore
    private unowned let dadFrame: TuringStoryDadFrameInteractionController
    private unowned let walkie: TuringStoryWalkieInteractionController
    private unowned let hamReceiver: TuringStoryHamReceiverInteractionController

    init(
        dadFrame: TuringStoryDadFrameInteractionController,
        walkie: TuringStoryWalkieInteractionController,
        hamReceiver: TuringStoryHamReceiverInteractionController,
        gate: TuringFlowInteractionGateController? = nil,
        arbiter: StoryInteractionArbiter = .shared,
        progress: Chapter01ProgressStore = .shared
    ) {
        self.dadFrame = dadFrame
        self.walkie = walkie
        self.hamReceiver = hamReceiver
        self.gate = gate ?? .shared
        self.arbiter = arbiter
        self.progress = progress
    }

    func prepareForChapterOpening(reason: String) async {
        dadFrame.stageBinding(.chapter01FourChancesDad, reason: reason)
        walkie.stageBinding(
            .chapter01OpeningWalkie,
            initialState: .closed,
            reason: reason
        )
        hamReceiver.stageBinding(.chapter01FourChancesHam, reason: reason)
        await gate.applyStableStatesAtomically(
            [
                .dadFrame: .closed,
                .walkie: .closed,
                .hamReceiver: .closed
            ],
            reason: reason
        )
    }

    func unlock(
        event: Chapter01RobotEncounterCompletionEvent
    ) async throws {
        guard event.releaseReport.isSafeForPostRobotHub else {
            throw Chapter01Error.robotReleaseBoundaryFailed
        }
        try await arbiter.requireCurrent(event.postRobotTransitionLease)
        let snapshot = try await progress.unlockPostRobotHub(
            sourceEventID: UUID()
        )
        try await install(
            snapshot: snapshot,
            transitionLease: event.postRobotTransitionLease,
            reason: "chapter01PostRobotHubUnlocked"
        )
    }

    func restore(
        snapshot: Chapter01ProgressSnapshot,
        transitionLease: StoryInteractionLease
    ) async throws {
        guard snapshot.postRobot.unlocked else {
            throw Chapter01Error.postRobotHubNotUnlocked
        }
        try await arbiter.requireCurrent(transitionLease)
        try await install(
            snapshot: snapshot,
            transitionLease: transitionLease,
            reason: "chapter01PostRobotHubRestored"
        )
    }

    private func install(
        snapshot: Chapter01ProgressSnapshot,
        transitionLease: StoryInteractionLease,
        reason: String
    ) async throws {
        for branch in snapshot.postRobot.completedBranches {
            try await TuringConversationContextRehydrator.rehydrate(
                terminalScriptPointID: branch.terminalScriptPointID
            )
        }

        dadFrame.stageBinding(.chapter01FourChancesDad, reason: reason)
        walkie.stageBinding(
            .chapter01FourChancesWalkie,
            initialState: snapshot.postRobot.state(for: .walkie),
            reason: reason
        )
        hamReceiver.stageBinding(.chapter01FourChancesHam, reason: reason)
        await gate.applyStableStatesAtomically(
            snapshot.postRobot.gateStates,
            reason: reason
        )
        await arbiter.release(
            transitionLease,
            reason: "\(reason).ready"
        )
    }
}
