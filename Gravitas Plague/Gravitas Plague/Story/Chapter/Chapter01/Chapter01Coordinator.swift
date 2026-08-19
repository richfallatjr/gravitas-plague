import Foundation
import simd

@MainActor
final class Chapter01Coordinator:
    TuringStoryCompletionEventSink,
    Chapter01DadWindowCompletionSink,
    Chapter01RobotEncounterCompletionSink,
    Chapter01DadFinalBattleCompletionSink {

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
    private let dadFinalBattleActionRouter:
        Chapter01DadFinalBattleActionRouter
    private let finalDadFrameInteractions:
        Chapter01FinalDadFrameInteractionCoordinator
    private let startRobot: RobotStarter
    private let cancelRobot: RobotCanceller

    private(set) var state: Chapter01State = .idle
    private var chapterRunID: UUID?
    private var storyTransitionLease: StoryInteractionLease?
    private var handledCompletionEventIDs = Set<UUID>()

    var onEpisodeBoundary: ((StoryEpisodeBoundaryEvent) async throws -> Void)?

    init(
        walkie: TuringStoryWalkieInteractionController,
        dad: Chapter01DadWindowCoordinator,
        progress: Chapter01ProgressStore = .shared,
        episodeFlow: TuringEpisodeFlowController = .shared,
        arbiter: StoryInteractionArbiter = .shared,
        postRobotInteractions: Chapter01PostRobotInteractionCoordinator,
        preDadFinalBattleBoundary: Chapter01PreDadFinalBattleBoundary,
        dadFinalBattleActionRouter:
            Chapter01DadFinalBattleActionRouter,
        finalDadFrameInteractions:
            Chapter01FinalDadFrameInteractionCoordinator,
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
        self.dadFinalBattleActionRouter = dadFinalBattleActionRouter
        self.finalDadFrameInteractions = finalDadFrameInteractions
        self.startRobot = startRobot
        self.cancelRobot = cancelRobot
    }

    func beginAtRoot(
        transitionLease: StoryInteractionLease? = nil
    ) async throws {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter01Error.stageNotEstablished
        }
        await cancel(reason: "beginAtRoot")
        if let transitionLease {
            try await arbiter.setStableInteractionPolicy(
                .unrestricted,
                storyTransitionLease: transitionLease,
                reason: "chapter01.beginAtRoot"
            )
        } else {
            await arbiter.resetStableInteractionPolicy(
                reason: "chapter01.beginAtRoot"
            )
        }
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
        StoryModeActionCoordinator.shared.activate(
            .init(
                episodeID: .chapter01,
                rootScriptPointID: "chapter01.walkie.rich.script06",
                durableBoundaryID: "chapter01.root.\(runID.uuidString)",
                sourceEventID: runID
            )
        )
        state = .rootReady
        print(
            "[Chapter01] root activated chapterRunID=\(runID.uuidString) scriptPointID=chapter01.walkie.rich.script06 mode=play noRescan=true"
        )
    }

    @discardableResult
    func resumeFromSavedCheckpoint(
        frozenSnapshot: Chapter01ProgressSnapshot? = nil,
        transitionLease suppliedTransitionLease: StoryInteractionLease? = nil
    ) async throws -> StoryTitleCardRouteLeaseDisposition {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter01Error.stageNotEstablished
        }
        let savedCandidate: Chapter01ProgressSnapshot?
        if let frozenSnapshot {
            savedCandidate = frozenSnapshot
        } else {
            savedCandidate = await progress.currentSnapshot()
        }
        guard let saved = savedCandidate,
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

        if checkpoint == .finalDadFramePending || checkpoint == .complete {
            let lease = try await continuationLease(
                suppliedTransitionLease,
                transitionID: transitionID,
                checkpoint: checkpoint
            )
            storyTransitionLease = lease
            do {
                try await finalDadFrameInteractions.restore(
                    snapshot: saved,
                    transitionLease: lease,
                    releaseWhenReady: suppliedTransitionLease == nil
                )
                storyTransitionLease = nil
                state = checkpoint == .complete
                    ? .complete
                    : .finalDadFramePending
                print(
                    "[Chapter01] continued final Dad-frame checkpoint=" +
                        "\(checkpoint.rawValue) battleReplayed=false " +
                        "roomRescan=false"
                )
                return suppliedTransitionLease == nil
                    ? .transferredByDestination
                    : .releaseAfterFade
            } catch {
                storyTransitionLease = nil
                await arbiter.release(
                    lease,
                    reason: "chapter01FinalDadFrameContinueFailed"
                )
                state = .failed(error.localizedDescription)
                throw error
            }
        }

        if checkpoint == .preDadFinalBattleReady {
            let lease = try await continuationLease(
                suppliedTransitionLease,
                transitionID: transitionID,
                checkpoint: checkpoint
            )
            storyTransitionLease = lease
            do {
                try await dadFinalBattleActionRouter.startFromContinuation(
                    snapshot: saved,
                    chapterRunID: runID,
                    transitionLease: lease
                )
                storyTransitionLease = nil
                state = .dadFinalBattle
                print(
                    "[Chapter01] continued directly into Dad final battle " +
                        "checkpoint=\(checkpoint.rawValue) " +
                        "chapterRunID=\(runID.uuidString) " +
                        "deviceStateRestored=false roomRescan=false"
                )
                return .transferredByDestination
            } catch {
                storyTransitionLease = nil
                await arbiter.release(
                    lease,
                    reason: "chapter01DadBattleContinueFailed"
                )
                state = .failed(error.localizedDescription)
                throw error
            }
        }

        if checkpoint == .postRobotHub {
            let lease = try await continuationLease(
                suppliedTransitionLease,
                transitionID: transitionID,
                checkpoint: checkpoint
            )
            storyTransitionLease = lease
            do {
                try await postRobotInteractions.restore(
                    snapshot: saved,
                    transitionLease: lease,
                    releaseWhenReady: suppliedTransitionLease == nil
                )
                storyTransitionLease = nil
                state = .postRobotHub
                print(
                    "[Chapter01] continued checkpoint=\(checkpoint.rawValue) chapterRunID=\(runID.uuidString) cinematicsReplayed=false roomRescan=false"
                )
                return suppliedTransitionLease == nil
                    ? .transferredByDestination
                    : .releaseAfterFade
            } catch {
                storyTransitionLease = nil
                await arbiter.release(lease, reason: "chapter01PostRobotContinueFailed")
                state = .failed(error.localizedDescription)
                throw error
            }
        }

        let lease = try await continuationLease(
            suppliedTransitionLease,
            transitionID: transitionID,
            checkpoint: checkpoint
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
        return .retainedByDestination
    }

    private func continuationLease(
        _ supplied: StoryInteractionLease?,
        transitionID: UUID,
        checkpoint: Chapter01Checkpoint
    ) async throws -> StoryInteractionLease {
        if let supplied {
            try await arbiter.requireCurrent(supplied)
            guard case .storyTransition = supplied.owner else {
                throw StoryInteractionClaimError.invalidTransfer
            }
            return supplied
        }
        return try await arbiter.claimStoryTransition(
            transitionID: transitionID,
            source: "chapter01Continue.\(checkpoint.rawValue)"
        )
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws -> TuringStoryCompletionDisposition {
        guard handledCompletionEventIDs.insert(event.eventID).inserted else {
            return .useDescriptorProgression
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

        case TuringStorySurfaceFlowBinding
            .chapter01DadEulogyScript03
            .terminalScriptPointID:
            guard let onEpisodeBoundary else {
                throw Chapter01Error.missingEpisodeBoundaryOwner
            }
            state = .ending
            try await onEpisodeBoundary(
                StoryEpisodeBoundaryEvent(
                    eventID: event.eventID,
                    completedEpisodeID: .chapter01,
                    actualTerminalPlaybackCompleted: true
                )
            )
            print(
                "[Chapter01FinalDadFrame] promptVoice completed " +
                    "actualPlaybackCompleted=true conversationSeedReady=true " +
                    "episodeEnded=true " +
                    "durableCheckpoint=chapter01.finalDadFrame.pending"
            )

        default:
            throw TuringRuntimeError.invalidConfig(
                "Unexpected Chapter 01 ScriptPoint completion: \(event.scriptPointID)"
            )
        }
        return .useDescriptorProgression
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        let openEndedKeys: Set<String> = [
            TuringStorySurfaceFlowBinding.chapter01FourChancesDad.conversationKey,
            TuringStorySurfaceFlowBinding.chapter01FourChancesWalkie.conversationKey,
            TuringStorySurfaceFlowBinding.chapter01FourChancesHam.conversationKey,
            TuringStorySurfaceFlowBinding.chapter01DadEulogyScript03.conversationKey
        ]
        guard openEndedKeys.contains(event.conversationKey) else {
            throw Chapter01Error.unexpectedConversationCompletion
        }
        print(
            "[Chapter01] open-ended conversation completed key=\(event.conversationKey) progression=none"
        )
    }

    func dadWindowMidpointReached(
        _ event: Chapter01DadWindowMidpointEvent
    ) async throws {
        guard let chapterRunID,
              event.chapterRunID == chapterRunID,
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
            "[Chapter01] Dad midpoint reached; Robot encounter accepted " +
                "chapterRunID=\(chapterRunID.uuidString) " +
                "elapsedSeconds=\(event.centeredIdleElapsedSeconds) " +
                "idleDurationSeconds=\(event.centeredIdleDurationSeconds)"
        )
    }

    func dadExitWalkStarted(
        _ event: Chapter01DadExitWalkStartedEvent
    ) async throws {
        guard let chapterRunID,
              event.chapterRunID == chapterRunID,
              event.locomotionActuallyStarted else {
            throw Chapter01Error.staleDadEvent
        }
        print(
            "[Chapter01] Dad exit locomotion started; " +
                "Robot encounter already active from Dad midpoint " +
                "chapterRunID=\(chapterRunID.uuidString)"
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

    func dadFinalBattleCompleted(
        _ event: Chapter01DadFinalBattleReleasedEvent
    ) async throws {
        guard let chapterRunID,
              event.chapterRunID == chapterRunID else {
            throw Chapter01Error.staleDadFinalBattleCompletion
        }
        try await finalDadFrameInteractions.unlockAfterBattle(event: event)
        state = .finalDadFramePending
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
            await preDadFinalBattleBoundary.publishIfNeeded(
                Chapter01PreDadFinalBattleReadyEvent(
                    chapterRunID: chapterRunID,
                    checkpointRevision: result.snapshot.revision,
                    sourceEventID: sourceEventID,
                    completedBranches: result.snapshot.postRobot.completedBranches
                )
            )
            state = .dadFinalBattle
        } else {
            try await postRobotInteractions.applyProgress(
                snapshot: result.snapshot,
                reason: "chapter01BranchCompleted.\(branch.rawValue)"
            )
            state = .postRobotHub
        }
    }

    func update(
        deltaTime: TimeInterval,
        playerTargetWorldPosition: SIMD3<Float>?
    ) {
        dad.update(deltaTime: deltaTime)
        dadFinalBattleActionRouter.update(
            deltaTime: deltaTime,
            playerTargetWorldPosition: playerTargetWorldPosition
        )
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
        await dadFinalBattleActionRouter.reset(reason: reason)
        chapterRunID = nil
        preDadFinalBattleBoundary.resetTransientPublicationState()
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        state = .cancelled
    }
}
