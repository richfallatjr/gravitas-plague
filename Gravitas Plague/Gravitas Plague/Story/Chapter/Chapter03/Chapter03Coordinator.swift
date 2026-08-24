import Foundation
import simd

@MainActor
final class Chapter03Coordinator:
    TuringStoryCompletionEventSink,
    Chapter03BikerBattleCompletionSink,
    Chapter03MikeBattleCompletionSink
{
    private let progress: Chapter03ProgressStore
    private let episodeFlow: TuringEpisodeFlowController
    private let arbiter: StoryInteractionArbiter
    private let bikerBattle: Chapter03BikerBattleCoordinator
    private let surfaces: Chapter03SurfaceSequenceCoordinator
    private let mikeBattle: Chapter03MikeBattleCoordinator
    private let roomPresentation: Chapter03RoomPresentationController
    private let definitionStore: Chapter03LightTunnelDefinitionStore
    private let lightTunnel: Chapter03LightTunnelCoordinator
    private let richVocalChannel: any StoryRichVocalChannelControlling
    private let layoutFingerprintProvider:
        () throws -> TuringStoryEstablishedLayoutFingerprint
    private weak var blackout: ImmersiveBlackoutController?

    private(set) var state: Chapter03State = .idle
    private var chapterRunID: UUID?
    private var titleTransitionLease: StoryInteractionLease?
    private var battleLease: StoryInteractionLease?
    private var activeBattleInstanceID: UUID?
    private var transitionLease: StoryInteractionLease?
    private var blackoutRequestID: UUID?
    private var pendingActivationCheckpoint: Chapter03Checkpoint?
    private var handledCompletionEventIDs = Set<UUID>()
    private var preparedLightTunnelDefinition:
        Chapter03LightTunnelResolvedDefinition?
    private var pendingHeavenBridgeDeathVocalToken:
        StoryPlayerDeathVocalToken?

    var onEndCardRequested: ((
        StoryTitleCardTransitionRequest,
        StoryInteractionLease,
        UUID
    ) throws -> Void)?
    var onFailure: ((Error) -> Void)?

    init(
        bikerBattle: Chapter03BikerBattleCoordinator,
        surfaces: Chapter03SurfaceSequenceCoordinator,
        mikeBattle: Chapter03MikeBattleCoordinator,
        roomPresentation: Chapter03RoomPresentationController,
        lightTunnel: Chapter03LightTunnelCoordinator,
        richVocalChannel: any StoryRichVocalChannelControlling,
        layoutFingerprintProvider:
            @escaping () throws -> TuringStoryEstablishedLayoutFingerprint,
        progress: Chapter03ProgressStore = .shared,
        definitionStore: Chapter03LightTunnelDefinitionStore = .init(),
        episodeFlow: TuringEpisodeFlowController = .shared,
        arbiter: StoryInteractionArbiter = .shared
    ) {
        self.bikerBattle = bikerBattle
        self.surfaces = surfaces
        self.mikeBattle = mikeBattle
        self.roomPresentation = roomPresentation
        self.lightTunnel = lightTunnel
        self.richVocalChannel = richVocalChannel
        self.layoutFingerprintProvider = layoutFingerprintProvider
        self.progress = progress
        self.definitionStore = definitionStore
        self.episodeFlow = episodeFlow
        self.arbiter = arbiter
        lightTunnel.onCompleted = { [weak self] event in
            await self?.lightTunnelCompleted(event)
        }
        lightTunnel.onFailed = { [weak self] runID, error in
            await self?.lightTunnelFailed(runID: runID, error: error)
        }
    }

    func bind(blackout: ImmersiveBlackoutController) {
        self.blackout = blackout
        roomPresentation.bind(blackout: blackout)
        mikeBattle.bind(blackout: blackout)
        lightTunnel.bind(blackout: blackout)
    }

    func beginAtRoot(
        chapterRunID: UUID,
        transitionLease: StoryInteractionLease,
        blackoutRequestID: UUID,
        resetProgress: Bool
    ) async throws {
        guard Chapter03RootPlan.current == .authoredOpening else {
            throw Chapter03Error.authoredOpeningUnavailable
        }
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter03Error.storyStageNotEstablished
        }
        guard let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }
        try await arbiter.requireCurrent(transitionLease)
        try blackout.requireFullBlackOwnership(requestID: blackoutRequestID)
        let before = try layoutFingerprintProvider()
        self.chapterRunID = chapterRunID
        preparedLightTunnelDefinition = nil
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        surfaces.closeAll(reason: "chapter03.root.preload")
        await episodeFlow.resetEpisode(reason: "chapter03.root")
        if resetProgress {
            _ = try await progress.resetForReplay(sourceEventID: chapterRunID)
        }
        _ = try await progress.commit(.bikerBattlePending, sourceEventID: UUID())
        let instanceID = UUID()
        let transferred = try await arbiter.transferStoryTransitionToBattle(
            storyTransitionLease: transitionLease,
            battleInstanceID: instanceID,
            reason: "chapter03.root.biker"
        )
        battleLease = transferred
        activeBattleInstanceID = instanceID
        state = .preparingBiker(chapterRunID)
        try await bikerBattle.prepare(
            chapterRunID: chapterRunID,
            battleInstanceID: instanceID,
            battleLease: transferred,
            completionSink: self
        )
        pendingActivationCheckpoint = .bikerBattlePending
        guard try layoutFingerprintProvider() == before else {
            throw Chapter03Error.layoutChangedDuringStart
        }
        print(
            "[Chapter03] production root prepared Biker under black runID=\(chapterRunID.uuidString) noRescan=true"
        )
    }

    func resumeFromSavedCheckpoint(
        snapshot: Chapter03ProgressSnapshot,
        transitionLease: StoryInteractionLease,
        requestID: UUID
    ) async throws -> StoryTitleCardRouteLeaseDisposition {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter03Error.storyStageNotEstablished
        }
        try await arbiter.requireCurrent(transitionLease)
        chapterRunID = requestID
        preparedLightTunnelDefinition = nil
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        surfaces.closeAll(reason: "chapter03.continue.preload")
        await episodeFlow.resetEpisode(
            reason: "chapter03.continue.\(snapshot.checkpoint.rawValue)"
        )

        switch snapshot.checkpoint {
        case .root, .bikerBattlePending:
            let instanceID = UUID()
            let transferred = try await arbiter.transferStoryTransitionToBattle(
                storyTransitionLease: transitionLease,
                battleInstanceID: instanceID,
                reason: "chapter03.continue.biker"
            )
            battleLease = transferred
            activeBattleInstanceID = instanceID
            state = .preparingBiker(requestID)
            try await bikerBattle.prepare(
                chapterRunID: requestID,
                battleInstanceID: instanceID,
                battleLease: transferred,
                completionSink: self
            )
            pendingActivationCheckpoint = .bikerBattlePending
            return .transferredByDestination

        case .bikerBattleCompleted:
            titleTransitionLease = transitionLease
            pendingActivationCheckpoint = .bikerBattleCompleted
            state = .walkieReady(requestID)
            return .retainedByDestination

        case .walkieCompleted:
            titleTransitionLease = transitionLease
            pendingActivationCheckpoint = .walkieCompleted
            state = .hamReady(requestID)
            return .retainedByDestination

        case .hamCompleted:
            titleTransitionLease = transitionLease
            pendingActivationCheckpoint = .hamCompleted
            state = .continuityBroadcastReady(requestID)
            return .retainedByDestination

        case .continuityBroadcastCompleted, .mikeBattlePending:
            try await prepareLightTunnelDefinition(
                chapterRunID: requestID,
                reason: "chapter03.continue.beforeMike"
            )
            let instanceID = UUID()
            let transferred = try await arbiter.transferStoryTransitionToBattle(
                storyTransitionLease: transitionLease,
                battleInstanceID: instanceID,
                reason: "chapter03.continue.mike"
            )
            battleLease = transferred
            activeBattleInstanceID = instanceID
            state = .preparingMike(requestID)
            try await mikeBattle.prepareAndStart(
                chapterRunID: requestID,
                battleInstanceID: instanceID,
                battleLease: transferred,
                completionSink: self,
                startImmediately: false
            )
            pendingActivationCheckpoint = .mikeBattlePending
            return .transferredByDestination

        case .heavenTransitionPending, .lightTunnelPending:
            guard let blackout else {
                throw StoryTitleCardError.missingPresentationOwner
            }
            try blackout.requireFullBlackOwnership(requestID: requestID)
            _ = try roomPresentation.suppressUnderFullBlack(transitionID: requestID)
            self.transitionLease = transitionLease
            self.blackoutRequestID = requestID
            try await startLightTunnel(
                chapterRunID: requestID,
                transitionLease: transitionLease,
                blackoutRequestID: requestID
            )
            return .destinationOwnsFullBlackAndLease

        case .endCardPending, .complete:
            titleTransitionLease = transitionLease
            state = .ending(requestID)
            return .releaseAfterFade
        }
    }

    func titleCardDidFullyFade(requestID: UUID) async throws {
        guard chapterRunID == requestID,
              let checkpoint = pendingActivationCheckpoint else { return }
        pendingActivationCheckpoint = nil
        switch checkpoint {
        case .bikerBattlePending:
            state = .bikerBattle(requestID)
            try bikerBattle.beginPreparedOpening()
        case .bikerBattleCompleted:
            await releaseTitleLease(reason: "chapter03.continue.walkie")
            surfaces.armWalkie(reason: "chapter03.continue.walkie")
        case .walkieCompleted:
            await releaseTitleLease(reason: "chapter03.continue.ham")
            surfaces.armHam(reason: "chapter03.continue.ham")
        case .hamCompleted:
            await releaseTitleLease(reason: "chapter03.continue.crank")
            surfaces.armCrank(reason: "chapter03.continue.crank")
        case .mikeBattlePending:
            state = .mikeBattle(requestID)
            try mikeBattle.beginPreparedOpening()
        default:
            break
        }
    }

    func update(
        deltaTime: TimeInterval,
        playerTargetWorldPosition: SIMD3<Float>?
    ) {
        lightTunnel.update(deltaTime: deltaTime)
        bikerBattle.update(
            deltaTime: deltaTime,
            playerTargetWorldPosition: playerTargetWorldPosition
        )
        mikeBattle.update(
            deltaTime: deltaTime,
            playerTargetWorldPosition: playerTargetWorldPosition
        )
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws -> TuringStoryCompletionDisposition {
        guard handledCompletionEventIDs.insert(event.eventID).inserted else {
            return .useDescriptorProgression
        }
        guard let chapterRunID else { throw Chapter03Error.staleRun }
        switch event.scriptPointID {
        case "chapter03.walkie.bigMike.scavengerReport.001",
             "chapter03.walkie.rich.connectsMen.002":
            return .useDescriptorProgression

        case "chapter03.walkie.bigMike.fading.003":
            _ = try await progress.commit(.walkieCompleted, sourceEventID: event.eventID)
            state = .hamReady(chapterRunID)
            surfaces.armHam(reason: "chapter03.walkie.completed")
            return .suppressDescriptorGateAndReleaseInteraction

        case "chapter03.hamReceiver.rich.faith.001":
            return .useDescriptorProgression

        case "chapter03.hamReceiver.cateye81.antichrist.002":
            _ = try await progress.commit(.hamCompleted, sourceEventID: event.eventID)
            state = .continuityBroadcastReady(chapterRunID)
            surfaces.armCrank(reason: "chapter03.ham.completed")
            return .suppressDescriptorGateAndReleaseInteraction

        case "chapter03.crankRadio.broadcaster.continuity.001":
            try await prepareLightTunnelDefinition(
                chapterRunID: chapterRunID,
                reason: "chapter03.continuity.beforeMike"
            )
            _ = try await progress.commit(
                .continuityBroadcastCompleted,
                sourceEventID: event.eventID
            )
            _ = try await progress.commit(.mikeBattlePending, sourceEventID: UUID())
            let instanceID = UUID()
            let lease = try await episodeFlow.transferActiveInteractionToBattle(
                battleInstanceID: instanceID,
                reason: "chapter03.continuity.completed"
            )
            surfaces.closeAll(reason: "chapter03.mikeBattle")
            activeBattleInstanceID = instanceID
            battleLease = lease
            state = .preparingMike(chapterRunID)
            try await mikeBattle.prepareAndStart(
                chapterRunID: chapterRunID,
                battleInstanceID: instanceID,
                battleLease: lease,
                completionSink: self
            )
            state = .mikeBattle(chapterRunID)
            return .interactionLeaseTransferred

        default:
            throw Chapter03Error.definitionInvalid(
                "Unexpected Chapter 3 completion: \(event.scriptPointID)"
            )
        }
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        throw Chapter03Error.definitionInvalid(
            "Chapter 3 opening exposes no conversation microphone: \(event.conversationKey)."
        )
    }

    func chapter03BikerBattleReleased(
        _ event: Chapter03BikerBattleReleasedEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID,
              event.battleInstanceID == activeBattleInstanceID,
              event.releaseReport.allHeavyEnemyRuntimesReleased,
              event.releaseReport.fullPortalReleased else {
            throw Chapter03Error.staleRun
        }
        try await arbiter.requireCurrent(event.battleLease)
        _ = try await progress.commit(
            .bikerBattleCompleted,
            sourceEventID: event.eventID
        )
        await arbiter.release(event.battleLease, reason: "chapter03.biker.completed")
        battleLease = nil
        activeBattleInstanceID = nil
        state = .walkieReady(event.chapterRunID)
        surfaces.armWalkie(reason: "chapter03.biker.completed")
    }

    func chapter03BikerBattleFailed(chapterRunID: UUID, error: Error) async {
        await fail(runID: chapterRunID, error: error)
    }

    func chapter03MikeBattleReleased(
        _ event: Chapter03MikeBattleReleasedEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID,
              event.battleInstanceID == activeBattleInstanceID else {
            throw Chapter03Error.staleRun
        }
        guard event.isSafeForHeaven else {
            throw Chapter03Error.definitionInvalid(
                "Mike-to-Heaven release rejected: " +
                    event.unsafeReasons.joined(separator: ", ")
            )
        }
        try await arbiter.requireCurrent(event.storyTransitionLease)
        _ = try await progress.commit(
            .heavenTransitionPending,
            sourceEventID: event.eventID
        )
        battleLease = nil
        activeBattleInstanceID = nil
        transitionLease = event.storyTransitionLease
        blackoutRequestID = event.blackoutRequestID
        pendingHeavenBridgeDeathVocalToken =
            event.heavenBridgeDeathVocalToken
        state = .suppressingRoom(event.chapterRunID)
        do {
            try await startLightTunnel(
                chapterRunID: event.chapterRunID,
                transitionLease: event.storyTransitionLease,
                blackoutRequestID: event.blackoutRequestID
            )
        } catch {
            stopPendingHeavenBridgeDeathVocal(
                reason: "lightTunnelStartFailed.\(error.localizedDescription)"
            )
            throw error
        }
    }

    func chapter03MikeBattleFailed(chapterRunID: UUID, error: Error) async {
        await fail(runID: chapterRunID, error: error)
    }

    func markEndCardRouteCommitted(sourceEventID: UUID) async throws {
        _ = try await progress.commit(.complete, sourceEventID: sourceEventID)
        state = .complete
        chapterRunID = nil
        preparedLightTunnelDefinition = nil
        transitionLease = nil
        blackoutRequestID = nil
    }

    func cancel(reason: String) async {
        await episodeFlow.cancelActiveSequence(reason: reason)
        await bikerBattle.cancel(reason: reason)
        await mikeBattle.cancel(reason: reason)
        await lightTunnel.cancel(reason: reason)
        stopPendingHeavenBridgeDeathVocal(reason: "chapterCancel.\(reason)")
        if let titleTransitionLease {
            self.titleTransitionLease = nil
            await arbiter.release(titleTransitionLease, reason: reason)
        }
        if let transitionLease {
            self.transitionLease = nil
            await arbiter.release(transitionLease, reason: reason)
        }
        chapterRunID = nil
        preparedLightTunnelDefinition = nil
        battleLease = nil
        activeBattleInstanceID = nil
        blackoutRequestID = nil
        pendingActivationCheckpoint = nil
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        state = .cancelled
    }

    private func startLightTunnel(
        chapterRunID: UUID,
        transitionLease: StoryInteractionLease,
        blackoutRequestID: UUID
    ) async throws {
        if preparedLightTunnelDefinition == nil {
            try await prepareLightTunnelDefinition(
                chapterRunID: chapterRunID,
                reason: "chapter03.tunnel.startFallback"
            )
        }
        guard let resolved = preparedLightTunnelDefinition else {
            throw Chapter03Error.definitionInvalid(
                "The validated Heaven tunnel definition was not retained."
            )
        }
        _ = try await progress.commit(.lightTunnelPending, sourceEventID: UUID())
        state = .preparingTunnel(chapterRunID)
        print(
            "[Chapter03Transition] starting Heaven tunnel " +
                "runID=\(chapterRunID.uuidString) " +
                "blackoutRequestID=\(blackoutRequestID.uuidString) " +
                "definitionPreflight=true"
        )
        try await lightTunnel.start(
            Chapter03LightTunnelRequest(
                chapterRunID: chapterRunID,
                interactionLease: transitionLease,
                blackoutRequestID: blackoutRequestID,
                resolvedDefinition: resolved
            )
        )
        if let token = pendingHeavenBridgeDeathVocalToken {
            richVocalChannel.relinquishPlayerDeathVocalToNaturalCompletion(
                token: token,
                reason: "chapter03HeavenTunnelStarted"
            )
            pendingHeavenBridgeDeathVocalToken = nil
        }
        preparedLightTunnelDefinition = nil
        state = .portalApproaching(chapterRunID)
        print(
            "[Chapter03] existing Heaven tunnel started after Mike/room full-black release runID=\(chapterRunID.uuidString)"
        )
    }

    private func lightTunnelCompleted(
        _ event: Chapter03LightTunnelCompletedEvent
    ) async {
        guard chapterRunID == event.chapterRunID,
              event.musicActuallyCompleted,
              transitionLease == event.interactionLease,
              blackoutRequestID == event.blackoutRequestID else { return }
        do {
            try await arbiter.requireCurrent(event.interactionLease)
            _ = try await progress.commit(
                .endCardPending,
                sourceEventID: event.completionEventID
            )
            state = .ending(event.chapterRunID)
            let request = StoryTitleCardTransitionRequest(
                requestID: event.blackoutRequestID,
                source: .naturalEpisodeBoundary,
                descriptor: StoryTitleCardCatalog.endOfAvailableContent,
                destination: .endOfAvailableContent(completedEpisode: .chapter03),
                menuMusicPolicy: .unchanged
            )
            print(
                "[Chapter03Transition] Heaven tunnel transferring full-black ownership " +
                    "chapterRunID=\(event.chapterRunID.uuidString) " +
                    "titleTransitionID=\(event.blackoutRequestID.uuidString) " +
                    "leaseOwner=\(event.interactionLease.owner)"
            )
            guard let onEndCardRequested else {
                throw StoryTitleCardError.missingRouteOwner
            }
            try onEndCardRequested(
                request,
                event.interactionLease,
                event.blackoutRequestID
            )
        } catch {
            await lightTunnelFailed(runID: event.chapterRunID, error: error)
        }
    }

    private func lightTunnelFailed(runID: UUID, error: Error) async {
        await fail(runID: runID, error: error)
    }

    private func prepareLightTunnelDefinition(
        chapterRunID: UUID,
        reason: String
    ) async throws {
        if preparedLightTunnelDefinition != nil { return }
        let resolved = try await definitionStore.loadProduction()
        preparedLightTunnelDefinition = resolved
        let angelPRName =
            resolved.angelPrerecording?.audioURL.lastPathComponent ?? "none"
        print(
            "[Chapter03Transition] Heaven tunnel preflight completed " +
                "runID=\(chapterRunID.uuidString) reason=\(reason) " +
                "music=\(resolved.musicURL.lastPathComponent) " +
                "musicDurationSeconds=\(resolved.musicDurationSeconds) " +
                "angelPR=\(angelPRName) " +
                "heavyVisualsLoaded=false"
        )
    }

    private func fail(runID: UUID, error: Error) async {
        guard chapterRunID == runID else { return }
        stopPendingHeavenBridgeDeathVocal(
            reason: "chapterFailure.\(error.localizedDescription)"
        )
        print(
            "[Chapter03Transition] FAILED runID=\(runID.uuidString) " +
                "state=\(String(describing: state)) " +
                "errorType=\(String(reflecting: type(of: error))) " +
                "error=\(error.localizedDescription)"
        )
        state = .failed(runID, error.localizedDescription)
        onFailure?(error)
    }

    private func releaseTitleLease(reason: String) async {
        guard let titleTransitionLease else { return }
        self.titleTransitionLease = nil
        await arbiter.release(titleTransitionLease, reason: reason)
    }

    private func stopPendingHeavenBridgeDeathVocal(reason: String) {
        guard let pendingHeavenBridgeDeathVocalToken else { return }
        richVocalChannel.stopPlayerDeathVocal(
            token: pendingHeavenBridgeDeathVocalToken,
            reason: reason
        )
        self.pendingHeavenBridgeDeathVocalToken = nil
    }
}
