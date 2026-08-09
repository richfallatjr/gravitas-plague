import Foundation
import simd

@MainActor
final class Chapter02Coordinator:
    TuringStoryCompletionEventSink,
    Chapter02WindowWomanCompletionSink,
    Chapter02WomanBattleCompletionSink
{
    private let progress: Chapter02ProgressStore
    private let episodeFlow: TuringEpisodeFlowController
    private let arbiter: StoryInteractionArbiter
    private let surfaces: Chapter02SurfaceSequenceCoordinator
    private let womanWindow: Chapter02WindowWomanCoordinator
    private let womanBattle: Chapter02WomanBattleCoordinator

    private(set) var state: Chapter02State = .idle
    private var chapterRunID: UUID?
    private var titleTransitionLease: StoryInteractionLease?
    private var battleLease: StoryInteractionLease?
    private var battleInstanceID: UUID?
    private var pendingActivationCheckpoint: Chapter02Checkpoint?
    private var pendingDirectBattleRestore = false
    private var pendingTerminalCard = false
    private var handledCompletionEventIDs = Set<UUID>()

    var onEpisodeBoundary: ((StoryEpisodeBoundaryEvent) async throws -> Void)?

    init(
        surfaces: Chapter02SurfaceSequenceCoordinator,
        womanWindow: Chapter02WindowWomanCoordinator,
        womanBattle: Chapter02WomanBattleCoordinator,
        progress: Chapter02ProgressStore = .shared,
        episodeFlow: TuringEpisodeFlowController = .shared,
        arbiter: StoryInteractionArbiter = .shared
    ) {
        self.surfaces = surfaces
        self.womanWindow = womanWindow
        self.womanBattle = womanBattle
        self.progress = progress
        self.episodeFlow = episodeFlow
        self.arbiter = arbiter
    }

    func beginAtRoot(
        transitionLease: StoryInteractionLease
    ) async throws {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter02Error.stageNotEstablished
        }
        await cancel(reason: "chapter02.beginAtRoot")
        try await arbiter.requireCurrent(transitionLease)
        try await arbiter.setStableInteractionPolicy(
            .unrestricted,
            storyTransitionLease: transitionLease,
            reason: "chapter02.beginAtRoot"
        )
        let runID = UUID()
        chapterRunID = runID
        titleTransitionLease = transitionLease
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        _ = try await progress.resetForReplay(sourceEventID: runID)
        await episodeFlow.resetEpisode(reason: "chapter02.root")
        surfaces.closeAll(reason: "chapter02.root.preload")
        pendingActivationCheckpoint = .root
        state = .loadingWomanRuntime
        try await womanWindow.prepareHidden(
            chapterRunID: runID,
            completionSink: self
        )
        print(
            "[Chapter02] root preloaded under black chapterRunID=\(runID.uuidString) " +
                "roomRescan=false spouseImports=1 presentationStarted=false"
        )
    }

    func resumeFromSavedCheckpoint(
        snapshot: Chapter02ProgressSnapshot,
        transitionLease: StoryInteractionLease
    ) async throws -> StoryTitleCardRouteLeaseDisposition {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter02Error.stageNotEstablished
        }
        await cancel(reason: "chapter02.continue")
        try await arbiter.requireCurrent(transitionLease)
        try await arbiter.setStableInteractionPolicy(
            .unrestricted,
            storyTransitionLease: transitionLease,
            reason: "chapter02.continue"
        )
        let runID = UUID()
        chapterRunID = runID
        titleTransitionLease = transitionLease
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        await episodeFlow.resetEpisode(
            reason: "chapter02.continue.\(snapshot.checkpoint.rawValue)"
        )
        surfaces.closeAll(reason: "chapter02.continue.preload")
        pendingActivationCheckpoint = snapshot.checkpoint

        switch snapshot.checkpoint {
        case .root,
             .missingPersonsCompleted,
             .dadHamCompleted,
             .bigMikeWalkieCompleted,
             .dadPhotoCompleted,
             .blackoutBroadcastCompleted,
             .womanExitPending,
             .womanBattlePending:
            state = .loadingWomanRuntime
            try await womanWindow.prepareHidden(
                chapterRunID: runID,
                completionSink: self
            )
            pendingDirectBattleRestore =
                snapshot.checkpoint == .womanBattlePending

        case .womanBattleCompleted,
             .postBattleHamCompleted:
            state = snapshot.checkpoint == .womanBattleCompleted
                ? .postBattleHamReady
                : .gravitasPSAReady

        case .gravitasPSACompleted, .complete:
            state = .ending
            pendingTerminalCard = true
        }

        print(
            "[Chapter02] continuation preloaded checkpoint=\(snapshot.checkpoint.rawValue) " +
                "roomRescan=false completedPointReplay=false"
        )
        return .retainedByDestination
    }

    func titleCardDidFullyFade(requestID: UUID) async throws {
        guard chapterRunID != nil,
              let checkpoint = pendingActivationCheckpoint else {
            return
        }
        pendingActivationCheckpoint = nil
        if pendingTerminalCard {
            state = .ending
            return
        }

        switch checkpoint {
        case .root,
             .missingPersonsCompleted,
             .dadHamCompleted,
             .bigMikeWalkieCompleted,
             .dadPhotoCompleted,
             .blackoutBroadcastCompleted,
             .womanExitPending:
            try womanWindow.activatePresentation()

        case .womanBattlePending:
            try await beginDirectBattleRestore()

        case .womanBattleCompleted:
            await releaseTitleTransitionLease(
                reason: "chapter02.continue.postBattle"
            )
            surfaces.armPostBattleHam(
                reason: "chapter02.continue.postBattle"
            )

        case .postBattleHamCompleted:
            await releaseTitleTransitionLease(
                reason: "chapter02.continue.gravitasPSA"
            )
            surfaces.armGravitasPSA(
                reason: "chapter02.continue.gravitasPSA"
            )

        case .gravitasPSACompleted, .complete:
            break
        }
    }

    func takeTerminalContinuationLease(
        requestID: UUID
    ) async throws -> StoryInteractionLease? {
        guard pendingTerminalCard else { return nil }
        guard let titleTransitionLease,
              titleTransitionLease.owner == .storyTransition(
                transitionID: requestID
              ) else {
            throw Chapter02Error.staleEvent
        }
        try await arbiter.requireCurrent(titleTransitionLease)
        pendingTerminalCard = false
        self.titleTransitionLease = nil
        return titleTransitionLease
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws -> TuringStoryCompletionDisposition {
        guard handledCompletionEventIDs.insert(event.eventID).inserted else {
            return .useDescriptorProgression
        }
        guard chapterRunID != nil else { throw Chapter02Error.missingRun }

        switch event.scriptPointID {
        case "chapter02.crankRadio.broadcaster.missingPersons.001":
            _ = try await progress.commit(
                .missingPersonsCompleted,
                sourceEventID: event.eventID
            )
            state = .dadHamReady
            surfaces.armDadHam(reason: "chapter02.missingPersons.completed")

        case "chapter02.hamReceiver.dad.script01",
             "chapter02.hamReceiver.rich.script02":
            break

        case "chapter02.hamReceiver.dad.script03":
            _ = try await progress.commit(
                .dadHamCompleted,
                sourceEventID: event.eventID
            )
            state = .bigMikeWalkieReady
            surfaces.armBigMikeWalkie(reason: "chapter02.dadHam.completed")

        case "chapter02.walkie.bigMike.script01",
             "chapter02.walkie.rich.script02":
            break

        case "chapter02.walkie.bigMike.script03":
            _ = try await progress.commit(
                .bigMikeWalkieCompleted,
                sourceEventID: event.eventID
            )
            state = .dadPhotoReady
            surfaces.armDadPhoto(reason: "chapter02.bigMikeWalkie.completed")

        case "chapter02.dadFrame.rich.dadDisappeared.001":
            _ = try await progress.commit(
                .dadPhotoCompleted,
                sourceEventID: event.eventID
            )
            state = .blackoutBroadcastReady
            surfaces.armGridFailure(reason: "chapter02.dadPhoto.completed")

        case "chapter02.crankRadio.broadcaster.gridFailure.002":
            _ = try await progress.commit(
                .blackoutBroadcastCompleted,
                sourceEventID: event.eventID
            )
            _ = try await progress.commit(
                .womanExitPending,
                sourceEventID: UUID()
            )
            let instanceID = UUID()
            battleInstanceID = instanceID
            battleLease = try await episodeFlow
                .transferActiveInteractionToBattle(
                    battleInstanceID: instanceID,
                    reason: "chapter02.gridFailure.completed"
                )
            surfaces.closeAll(reason: "chapter02.womanExit")
            state = .womanExitingWindow
            womanWindow.requestExit()

        case "chapter02.hamReceiver.rich.revelation.001":
            break

        case "chapter02.hamReceiver.cateye81.revelation.002":
            _ = try await progress.commit(
                .postBattleHamCompleted,
                sourceEventID: event.eventID
            )
            state = .gravitasPSAReady
            surfaces.armGravitasPSA(reason: "chapter02.postBattleHam.completed")

        case "chapter02.crankRadio.broadcaster.gravitasPSA.003":
            _ = try await progress.commit(
                .gravitasPSACompleted,
                sourceEventID: event.eventID
            )
            _ = try await progress.commit(
                .complete,
                sourceEventID: UUID()
            )
            state = .ending
            try await emitEpisodeBoundary(sourceEventID: event.eventID)

        default:
            throw Chapter02Error.unexpectedCompletion(event.scriptPointID)
        }
        return .useDescriptorProgression
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        let validKeys: Set<String> = [
            TuringStorySurfaceFlowBinding.chapter02CrankMissingPersons.conversationKey,
            TuringStorySurfaceFlowBinding.chapter02DadHam.conversationKey,
            TuringStorySurfaceFlowBinding.chapter02BigMikeWalkie.conversationKey,
            TuringStorySurfaceFlowBinding.chapter02DadPhoto.conversationKey,
            TuringStorySurfaceFlowBinding.chapter02CrankGridFailure.conversationKey,
            TuringStorySurfaceFlowBinding.chapter02PostBattleHam.conversationKey,
            TuringStorySurfaceFlowBinding.chapter02CrankGravitasPSA.conversationKey
        ]
        guard validKeys.contains(event.conversationKey) else {
            throw Chapter02Error.unexpectedCompletion(event.conversationKey)
        }
        print(
            "[Chapter02] open-ended conversation completed key=\(event.conversationKey) progression=none"
        )
    }

    func womanWindowPresentationReady(
        _ event: Chapter02WomanWindowReadyEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID,
              let checkpoint = await progress.currentSnapshot()?.checkpoint else {
            throw Chapter02Error.staleEvent
        }
        if checkpoint == .blackoutBroadcastCompleted ||
            checkpoint == .womanExitPending {
            try await transferTitleLeaseToBattleAndExit()
            return
        }
        await releaseTitleTransitionLease(
            reason: "chapter02.windowPresentationReady"
        )
        surfaces.restore(
            checkpoint: checkpoint,
            reason: "chapter02.windowPresentationReady"
        )
        state = stateForReadyCheckpoint(checkpoint)
    }

    func womanStagedForDoor(
        _ event: Chapter02WomanStagedForDoorEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID,
              let chapterRunID,
              let battleInstanceID,
              let battleLease else {
            throw Chapter02Error.staleEvent
        }
        _ = try await progress.commit(
            .womanBattlePending,
            sourceEventID: UUID()
        )
        let runtime = try womanWindow.takeStagedRuntime()
        self.battleLease = nil
        state = .womanBattle
        womanBattle.start(
            chapterRunID: chapterRunID,
            runtime: runtime,
            battleInstanceID: battleInstanceID,
            battleLease: battleLease,
            completionSink: self
        )
    }

    func womanWindowFailed(chapterRunID: UUID, message: String) async {
        guard chapterRunID == self.chapterRunID else { return }
        state = .failed(message)
        await releaseTitleTransitionLease(reason: "chapter02.windowFailed")
        if let battleLease {
            self.battleLease = nil
            await arbiter.release(battleLease, reason: "chapter02.windowFailed")
        }
    }

    func womanBattleReleased(
        _ event: Chapter02WomanBattleReleasedEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID,
              event.heavyRuntimeReleased,
              event.fullPortalReleased else {
            throw Chapter02Error.staleEvent
        }
        _ = try await progress.commit(
            .womanBattleCompleted,
            sourceEventID: event.battleInstanceID
        )
        battleInstanceID = nil
        state = .postBattleHamReady
        surfaces.armPostBattleHam(reason: "chapter02.womanBattle.released")
    }

    func womanBattleFailed(chapterRunID: UUID, message: String) async {
        guard chapterRunID == self.chapterRunID else { return }
        state = .failed(message)
    }

    func update(
        deltaTime: TimeInterval,
        playerTargetWorldPosition: SIMD3<Float>?
    ) {
        womanWindow.update(deltaTime: deltaTime)
        womanBattle.update(
            deltaTime: deltaTime,
            playerTargetWorldPosition: playerTargetWorldPosition
        )
    }

    func cancel(reason: String) async {
        await episodeFlow.cancelActiveSequence(reason: reason)
        await womanWindow.cancel(reason: reason)
        await womanBattle.cancel(reason: reason)
        if let titleTransitionLease {
            self.titleTransitionLease = nil
            await arbiter.release(titleTransitionLease, reason: reason)
        }
        if let battleLease {
            self.battleLease = nil
            await arbiter.release(battleLease, reason: reason)
        }
        chapterRunID = nil
        battleInstanceID = nil
        pendingActivationCheckpoint = nil
        pendingDirectBattleRestore = false
        pendingTerminalCard = false
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        state = .cancelled
    }

    private func transferTitleLeaseToBattleAndExit() async throws {
        guard let titleTransitionLease else {
            throw Chapter02Error.staleEvent
        }
        let instanceID = UUID()
        let transferred = try await arbiter.transferStoryTransitionToBattle(
            storyTransitionLease: titleTransitionLease,
            battleInstanceID: instanceID,
            reason: "chapter02.continue.womanExit"
        )
        self.titleTransitionLease = nil
        battleLease = transferred
        battleInstanceID = instanceID
        surfaces.closeAll(reason: "chapter02.continue.womanExit")
        state = .womanExitingWindow
        womanWindow.requestExit()
    }

    private func beginDirectBattleRestore() async throws {
        guard pendingDirectBattleRestore,
              let chapterRunID,
              let titleTransitionLease else {
            throw Chapter02Error.staleEvent
        }
        pendingDirectBattleRestore = false
        try await womanWindow.stageHiddenRuntimeForDoor()
        let instanceID = UUID()
        let transferred = try await arbiter.transferStoryTransitionToBattle(
            storyTransitionLease: titleTransitionLease,
            battleInstanceID: instanceID,
            reason: "chapter02.continue.womanBattle"
        )
        self.titleTransitionLease = nil
        battleInstanceID = instanceID
        _ = try await progress.commit(
            .womanBattlePending,
            sourceEventID: UUID()
        )
        let runtime = try womanWindow.takeStagedRuntime()
        state = .womanBattle
        womanBattle.start(
            chapterRunID: chapterRunID,
            runtime: runtime,
            battleInstanceID: instanceID,
            battleLease: transferred,
            completionSink: self
        )
    }

    private func releaseTitleTransitionLease(reason: String) async {
        guard let titleTransitionLease else { return }
        self.titleTransitionLease = nil
        await arbiter.release(titleTransitionLease, reason: reason)
    }

    private func emitEpisodeBoundary(sourceEventID: UUID) async throws {
        guard let onEpisodeBoundary else {
            throw Chapter02Error.missingEpisodeBoundaryOwner
        }
        try await onEpisodeBoundary(
            StoryEpisodeBoundaryEvent(
                eventID: sourceEventID,
                completedEpisodeID: .chapter02,
                actualTerminalPlaybackCompleted: true
            )
        )
    }

    private func stateForReadyCheckpoint(
        _ checkpoint: Chapter02Checkpoint
    ) -> Chapter02State {
        switch checkpoint {
        case .root: return .missingPersonsReady
        case .missingPersonsCompleted: return .dadHamReady
        case .dadHamCompleted: return .bigMikeWalkieReady
        case .bigMikeWalkieCompleted: return .dadPhotoReady
        case .dadPhotoCompleted: return .blackoutBroadcastReady
        case .womanBattleCompleted: return .postBattleHamReady
        case .postBattleHamCompleted: return .gravitasPSAReady
        case .blackoutBroadcastCompleted,
             .womanExitPending,
             .womanBattlePending:
            return .womanExitingWindow
        case .gravitasPSACompleted, .complete:
            return .ending
        }
    }
}
