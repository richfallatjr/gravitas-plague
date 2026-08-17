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
        transitionLease: StoryInteractionLease,
        releaseWhenReady: Bool = true
    ) async throws {
        guard snapshot.postRobot.unlocked else {
            throw Chapter01Error.postRobotHubNotUnlocked
        }
        try await arbiter.requireCurrent(transitionLease)
        try await install(
            snapshot: snapshot,
            transitionLease: transitionLease,
            reason: "chapter01PostRobotHubRestored",
            releaseWhenReady: releaseWhenReady
        )
    }

    func applyProgress(
        snapshot: Chapter01ProgressSnapshot,
        reason: String
    ) async throws {
        guard snapshot.postRobot.unlocked else {
            throw Chapter01Error.postRobotHubNotUnlocked
        }
        try await applySnapshot(snapshot, reason: reason)
    }

    private func install(
        snapshot: Chapter01ProgressSnapshot,
        transitionLease: StoryInteractionLease,
        reason: String,
        releaseWhenReady: Bool = true
    ) async throws {
        try await applySnapshot(snapshot, reason: reason)
        if releaseWhenReady {
            let releasedSnapshot = await arbiter.releaseAndCurrentSnapshot(
                transitionLease,
                reason: "\(reason).ready"
            )
            let mode = StoryExperienceModeController.shared.modeForNewStoryAction()
            let presentationIsValid = mode == .play
                ? releasedSnapshot.dadFramePresentation == .hidden &&
                    releasedSnapshot.capabilities.contains(.dadFramePlay) == false
                : releasedSnapshot.dadFramePresentation == .play &&
                    releasedSnapshot.capabilities.contains(.dadFramePlay)
            guard releasedSnapshot.exclusiveOwner == nil,
                  releasedSnapshot.doorState == .closedUnloaded,
                  presentationIsValid else {
                print(
                    "[Chapter01PostRobot] ERROR first branch presentation rejected " +
                        "owner=\(releasedSnapshot.exclusiveOwner?.logValue ?? "none") " +
                        "doorState=\(releasedSnapshot.doorState.rawValue) " +
                        "dadFrame=\(releasedSnapshot.dadFramePresentation.rawValue) " +
                        "capabilities=\(releasedSnapshot.capabilities.map(\.rawValue).sorted())"
                )
                throw Chapter01Error.postRobotBranchNotAvailable(.dadFrame)
            }

            // Apply the authoritative release snapshot immediately. The stream
            // remains the normal update path, but it cannot drop the first hub
            // action while its observer is resuming after the battle teardown.
            dadFrame.applyInteractionSnapshot(releasedSnapshot)
            walkie.applyInteractionSnapshot(releasedSnapshot)
            hamReceiver.applyInteractionSnapshot(releasedSnapshot)
            print(
                "[Chapter01PostRobot] first branch presented synchronously " +
                    "dadFrame=\(releasedSnapshot.dadFramePresentation.rawValue) mode=\(mode.rawValue)"
            )
        }
    }

    private func applySnapshot(
        _ snapshot: Chapter01ProgressSnapshot,
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
        if let branch = Chapter01PostRobotBranch.allCases.first(
            where: {
                snapshot.postRobot.isAvailable($0) &&
                    snapshot.postRobot.completedBranches.contains($0) == false
            }
        ) {
            let binding: TuringStorySurfaceFlowBinding
            switch branch {
            case .dadFrame:
                binding = .chapter01FourChancesDad
            case .walkie:
                binding = .chapter01FourChancesWalkie
            case .hamReceiver:
                binding = .chapter01FourChancesHam
            }
            let mode = StoryExperienceModeController.shared.modeForNewStoryAction()
            StoryModeActionCoordinator.shared.activate(
                .init(
                    episodeID: .chapter01,
                    rootScriptPointID: binding.rootScriptPointID,
                    durableBoundaryID:
                        "chapter01.postRobot.\(snapshot.revision).\(branch.rawValue)",
                    sourceEventID: UUID()
                ),
                mode: mode,
                interactiveArm: { }
            )
        }
        print(
            "[Chapter01PostRobot] sequential gates applied " +
                "dad=\(snapshot.postRobot.state(for: .dadFrame).rawValue) " +
                "walkie=\(snapshot.postRobot.state(for: .walkie).rawValue) " +
                "ham=\(snapshot.postRobot.state(for: .hamReceiver).rawValue) " +
                "reason=\(reason)"
        )
    }
}
