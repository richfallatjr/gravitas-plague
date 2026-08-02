import Foundation

@MainActor
final class Chapter01Coordinator:
    TuringStoryCompletionEventSink,
    Chapter01DadWindowCompletionSink,
    Chapter01RobotEncounterCompletionSink {

    typealias RobotStarter = @MainActor (
        UUID,
        StoryInteractionLease,
        any Chapter01RobotEncounterCompletionSink
    ) async throws -> Void

    typealias RobotCanceller = @MainActor (String) async -> Void

    private let progress: Chapter01ProgressStore
    private let episodeFlow: TuringEpisodeFlowController
    private let arbiter: StoryInteractionArbiter
    private let walkie: TuringStoryWalkieInteractionController
    private let dad: Chapter01DadWindowCoordinator
    private let postRobotInteractions: Chapter01PostRobotInteractionCoordinator
    private let preDadFinalBattleBoundary: Chapter01PreDadFinalBattleBoundary
    private let startRobot: RobotStarter
    private let cancelRobot: RobotCanceller

    private(set) var state: Chapter01State = .idle
    private var chapterRunID: UUID?
    private var storyTransitionLease: StoryInteractionLease?
    private var handledCompletionEventIDs = Set<UUID>()

    init(
        walkie: TuringStoryWalkieInteractionController,
        dad: Chapter01DadWindowCoordinator,
        progress: Chapter01ProgressStore = .shared,
        episodeFlow: TuringEpisodeFlowController = .shared,
        arbiter: StoryInteractionArbiter = .shared,
        postRobotInteractions: Chapter01PostRobotInteractionCoordinator,
        preDadFinalBattleBoundary: Chapter01PreDadFinalBattleBoundary,
        startRobot: @escaping RobotStarter,
        cancelRobot: @escaping RobotCanceller
    ) {
        self.walkie = walkie
        self.dad = dad
        self.progress = progress
        self.episodeFlow = episodeFlow
        self.arbiter = arbiter
        self.postRobotInteractions = postRobotInteractions
        self.preDadFinalBattleBoundary = preDadFinalBattleBoundary
        self.startRobot = startRobot
        self.cancelRobot = cancelRobot
    }

    func beginAtRoot() async throws {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter01Error.stageNotEstablished
        }
        await cancel(reason: "beginAtRoot")
        try await dad.validateAvailability()

        let runID = UUID()
        chapterRunID = runID
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        _ = try await progress.resetForReplay(sourceEventID: runID)
        await episodeFlow.resetEpisode(reason: "chapter01.root")
        await postRobotInteractions.prepareForChapterOpening(
            reason: "chapter01.root"
        )
        walkie.episodeStarted(.chapter01)
        walkie.bind(
            .chapter01OpeningWalkie,
            initialState: .play,
            reason: "chapter01.root"
        )
        walkie.armPlay(
            action: .startScriptPoint(
                id: "chapter01.walkie.rich.script06",
                trigger: .userPlay
            ),
            reason: "chapter01.root"
        )
        state = .rootReady
        print(
            "[Chapter01] root armed chapterRunID=\(runID.uuidString) scriptPointID=chapter01.walkie.rich.script06 noRescan=true"
        )
    }

    func resumeFromSavedCheckpoint() async throws {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter01Error.stageNotEstablished
        }
        guard let saved = await progress.currentSnapshot(),
              let checkpoint = saved.checkpoint
                .supportedContinuationCheckpoint else {
            throw Chapter01Error.unsupportedContinuationCheckpoint
        }

        await cancel(reason: "resumeFromSavedCheckpoint")
        try await dad.validateAvailability()

        let runID = UUID()
        let transitionID = UUID()
        chapterRunID = runID
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        await episodeFlow.resetEpisode(
            reason: "chapter01.continue.\(checkpoint.rawValue)"
        )
        walkie.episodeStarted(.chapter01)

        if checkpoint == .postRobotHub || checkpoint == .preDadFinalBattleReady {
            let lease = try await arbiter.claimStoryTransition(
                transitionID: transitionID,
                source: "chapter01Continue.\(checkpoint.rawValue)"
            )
            storyTransitionLease = lease
            do {
                try await postRobotInteractions.restore(
                    snapshot: saved,
                    transitionLease: lease
                )
                storyTransitionLease = nil
                state = checkpoint == .preDadFinalBattleReady
                    ? .preDadFinalBattleReady
                    : .postRobotHub
                if checkpoint == .preDadFinalBattleReady {
                    await preDadFinalBattleBoundary.publishIfNeeded(
                        Chapter01PreDadFinalBattleReadyEvent(
                            chapterRunID: runID,
                            checkpointRevision: saved.revision,
                            sourceEventID: saved.sourceEventIDs.first ?? UUID(),
                            completedBranches: saved.postRobot.completedBranches
                        )
                    )
                }
                print(
                    "[Chapter01] continued checkpoint=\(checkpoint.rawValue) chapterRunID=\(runID.uuidString) cinematicsReplayed=false roomRescan=false"
                )
                return
            } catch {
                storyTransitionLease = nil
                await arbiter.release(lease, reason: "chapter01PostRobotContinueFailed")
                state = .failed(error.localizedDescription)
                throw error
            }
        }

        let lease = try await arbiter.claimStoryTransition(
            transitionID: transitionID,
            source: "chapter01Continue.\(checkpoint.rawValue)"
        )
        storyTransitionLease = lease
        state = .dadWindow

        do {
            try await dad.start(
                request: Chapter01DadWindowRequest(
                    chapterRunID: runID,
                    storyTransitionLease: lease,
                    completionSink: self
                )
            )
        } catch {
            storyTransitionLease = nil
            await arbiter.release(
                lease,
                reason: "chapter01ContinueDadStartFailed"
            )
            state = .failed(error.localizedDescription)
            throw error
        }

        print(
            "[Chapter01] continued checkpoint=\(checkpoint.rawValue) chapterRunID=\(runID.uuidString) scriptsReplayed=false roomRescan=false"
        )
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws {
        guard handledCompletionEventIDs.insert(event.eventID).inserted else {
            return
        }
        guard let chapterRunID else {
            throw Chapter01Error.missingRun
        }

        switch event.scriptPointID {
        case "chapter01.walkie.rich.script06":
            _ = try await progress.commit(
                .script06Completed,
                sourceEventID: event.eventID
            )
            state = .script07

        case "chapter01.walkie.bigMike.script07":
            _ = try await progress.commit(
                .script07Completed,
                sourceEventID: event.eventID
            )
            _ = try await progress.commit(
                .dadWindowPending,
                sourceEventID: UUID()
            )

            let lease = try await episodeFlow
                .transferActiveInteractionToStoryTransition(
                    transitionID: UUID(),
                    reason: "chapter01Script07Completed"
                )
            storyTransitionLease = lease
            state = .dadWindow
            do {
                try await dad.start(
                    request: Chapter01DadWindowRequest(
                        chapterRunID: chapterRunID,
                        storyTransitionLease: lease,
                        completionSink: self
                    )
                )
            } catch {
                storyTransitionLease = nil
                await arbiter.release(
                    lease,
                    reason: "chapter01DadStartFailed"
                )
                state = .failed(error.localizedDescription)
                throw error
            }

        case Chapter01PostRobotBranch.dadFrame.terminalScriptPointID:
            try await completePostRobotBranch(
                .dadFrame,
                terminalScriptPointID: event.scriptPointID,
                sourceEventID: event.eventID
            )

        case "chapter01.walkie.rich.script08":
            break

        case Chapter01PostRobotBranch.walkie.terminalScriptPointID:
            try await completePostRobotBranch(
                .walkie,
                terminalScriptPointID: event.scriptPointID,
                sourceEventID: event.eventID
            )

        case "chapter01.hamReceiver.rich.script04":
            break

        case Chapter01PostRobotBranch.hamReceiver.terminalScriptPointID:
            try await completePostRobotBranch(
                .hamReceiver,
                terminalScriptPointID: event.scriptPointID,
                sourceEventID: event.eventID
            )

        default:
            throw TuringRuntimeError.invalidConfig(
                "Unexpected Chapter 01 ScriptPoint completion: \(event.scriptPointID)"
            )
        }
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        let openEndedKeys: Set<String> = [
            TuringStorySurfaceFlowBinding.chapter01FourChancesDad.conversationKey,
            TuringStorySurfaceFlowBinding.chapter01FourChancesWalkie.conversationKey,
            TuringStorySurfaceFlowBinding.chapter01FourChancesHam.conversationKey
        ]
        guard openEndedKeys.contains(event.conversationKey) else {
            throw Chapter01Error.unexpectedConversationCompletion
        }
        print(
            "[Chapter01] open-ended conversation completed key=\(event.conversationKey) progression=none"
        )
    }

    func dadExitWalkStarted(
        _ event: Chapter01DadExitWalkStartedEvent
    ) async throws {
        guard let chapterRunID,
              event.chapterRunID == chapterRunID,
              event.locomotionActuallyStarted,
              let lease = storyTransitionLease,
              lease == event.storyTransitionLease else {
            throw Chapter01Error.staleDadEvent
        }

        _ = try await progress.commit(
            .robotEncounterPending,
            sourceEventID: UUID()
        )
        try await startRobot(chapterRunID, lease, self)
        storyTransitionLease = nil
        state = .robot
        print(
            "[Chapter01] Dad exit locomotion started; Robot encounter accepted chapterRunID=\(chapterRunID.uuidString)"
        )
    }

    func dadRuntimeReleased(
        _ event: Chapter01DadRuntimeReleasedEvent
    ) async {
        guard event.chapterRunID == chapterRunID else { return }
        print(
            "[Chapter01] Dad runtime release acknowledged heavyRuntimeReleased=\(event.releaseReport.heavyRuntimeReleased)"
        )
    }

    func dadWindowFailed(
        _ event: Chapter01DadWindowFailureEvent
    ) async {
        guard event.chapterRunID == chapterRunID else { return }
        state = .failed(event.message)
        print(
            "[Chapter01] ERROR Dad window failed chapterRunID=\(event.chapterRunID.uuidString) message=\(event.message)"
        )
        if let storyTransitionLease {
            self.storyTransitionLease = nil
            await arbiter.release(
                storyTransitionLease,
                reason: "chapter01DadWindowFailed"
            )
        }
    }

    func robotEncounterCompleted(
        _ event: Chapter01RobotEncounterCompletionEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID else {
            throw Chapter01Error.missingRun
        }
        try await postRobotInteractions.unlock(event: event)
        state = .postRobotHub
        print(
            "[Chapter01] Robot encounter completed; three-device hub unlocked"
        )
    }

    func robotEncounterFailed(
        _ event: Chapter01RobotEncounterFailureEvent
    ) async {
        guard event.chapterRunID == chapterRunID else { return }
        state = .failed(event.message)
    }

    private func completePostRobotBranch(
        _ branch: Chapter01PostRobotBranch,
        terminalScriptPointID: String,
        sourceEventID: UUID
    ) async throws {
        guard let chapterRunID else {
            throw Chapter01Error.missingRun
        }
        let result = try await progress.completePostRobotBranch(
            branch,
            terminalScriptPointID: terminalScriptPointID,
            sourceEventID: sourceEventID
        )
        if result.becameAllBranchesComplete {
            state = .preDadFinalBattleReady
            await preDadFinalBattleBoundary.publishIfNeeded(
                Chapter01PreDadFinalBattleReadyEvent(
                    chapterRunID: chapterRunID,
                    checkpointRevision: result.snapshot.revision,
                    sourceEventID: sourceEventID,
                    completedBranches: result.snapshot.postRobot.completedBranches
                )
            )
        } else {
            state = .postRobotHub
        }
    }

    func update(deltaTime: TimeInterval) {
        dad.update(deltaTime: deltaTime)
    }

    func cancel(reason: String) async {
        await episodeFlow.cancelActiveSequence(reason: reason)
        await dad.cancel(reason: reason)
        await cancelRobot(reason)
        if let storyTransitionLease {
            self.storyTransitionLease = nil
            await arbiter.release(storyTransitionLease, reason: reason)
        }
        if let chapterRunID {
            await Chapter01MusicController.shared.stopAll(
                chapterRunID: chapterRunID,
                reason: reason
            )
        }
        chapterRunID = nil
        preDadFinalBattleBoundary.resetTransientPublicationState()
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        state = .cancelled
    }
}
