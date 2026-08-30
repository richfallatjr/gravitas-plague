import Foundation

@MainActor
final class TuringLiveConversationSessionCoordinator:
    TuringConversationLifecycleSink,
    TuringFlowPlaybackLifecycleSink
{
    static let shared = TuringLiveConversationSessionCoordinator()
    static let submittedQuestionHold: Duration = .seconds(2)
    private static let prerecordingPreFillerRevealTimeout: Duration = .seconds(5)

    private struct Attachment {
        let parentSequenceID: UUID
        let parentLease: StoryInteractionLease
        let descriptor: TuringFlowDescriptor
        let identity: TuringFlowIdentity
        let playback: any TuringFlowPlaybackControlling
        let spokenPlayback: any TuringSpokenCoverControlling
        let microphoneGeneration: UInt64
    }

    private let arbiter = StoryInteractionArbiter.shared
    private let computeAdmission = TuringLiveConversationComputeAdmission.shared
    private let filler = TuringLiveConversationInitialFillerController.shared

    private var generation: UInt64 = 0
    private var attachment: Attachment?
    private var session: TuringLiveConversationSession?
    private var turns: [UUID: TuringLiveConversationTurn] = [:]
    private var activeResponseTurnID: UUID?
    private var waitingResponseTurnID: UUID?
    private var presentedSeedIDs: [StoryInteractionSurfaceID: UUID] = [:]
    private var currentAuthoredSeed: TuringLiveConversationSeed?
    private var currentAuthoredItemID: String?
    private var pendingHoldSurface: StoryInteractionSurfaceID?
    private var pendingHoldEndRequested = false
    private weak var hudEventSink: (any TuringLiveConversationHUDEventSink)?

    private init() {}

    func attach(
        parentSequenceID: UUID,
        parentLease: StoryInteractionLease,
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        playback: any TuringFlowPlaybackControlling
    ) async throws {
        guard let spokenPlayback = playback as? any TuringSpokenCoverControlling else {
            throw TuringRuntimeError.invalidConfig(
                "Authored playback does not support exact spoken-cover pause and resume."
            )
        }
        if let liveSession = session,
           liveSession.parentLease.id == parentLease.id,
           liveSession.progressionHold == nil,
           liveSession.activeTurnID == nil,
           turns.isEmpty {
            try await replaceAttachmentPreservingRetainedAvailability(
                parentSequenceID: parentSequenceID,
                parentLease: parentLease,
                descriptor: descriptor,
                identity: identity,
                playback: playback,
                spokenPlayback: spokenPlayback,
                previousSession: liveSession
            )
            return
        }
        await detach(reason: "replaceAttachment")
        generation &+= 1
        let microphoneGeneration =
            await arbiter.currentConversationMicrophoneGeneration()
        attachment = Attachment(
            parentSequenceID: parentSequenceID,
            parentLease: parentLease,
            descriptor: descriptor,
            identity: identity,
            playback: playback,
            spokenPlayback: spokenPlayback,
            microphoneGeneration: microphoneGeneration
        )
        await playback.setPlaybackLifecycleSink(self)
        print("[TuringLiveConversation] attached sequenceID=\(parentSequenceID.uuidString) flowInstanceID=\(identity.flowInstanceID.uuidString)")
    }

    func authoredFlowDidComplete(reason: String) async {
        guard let liveSession = session,
              liveSession.activeTurnID == nil,
              turns.isEmpty else {
            return
        }
        currentAuthoredItemID = nil
        currentAuthoredSeed = nil
        if await restoreRetainedAvailabilityIfPossible(
            session: liveSession,
            reason: reason
        ) {
            print(
                "[TuringLiveConversation] authored flow completed; " +
                    "retained microphones remain active reason=\(reason)"
            )
            return
        }
        presentedSeedIDs.removeAll(keepingCapacity: false)
        await finishSessionIfIdle(reason: reason)
    }

    func detach(reason: String) async {
        generation &+= 1
        let parentPlayback = attachment?.playback
        await parentPlayback?.setPlaybackLifecycleSink(nil)
        for turn in turns.values {
            await cancelTurn(turn, reason: reason, publishFailure: false)
        }
        turns.removeAll(keepingCapacity: false)
        activeResponseTurnID = nil
        waitingResponseTurnID = nil
        if let session {
            await arbiter.removeLiveConversationSession(
                parentLease: session.parentLease,
                sessionID: session.sessionID,
                generation: session.generation,
                reason: reason
            )
            if let progressionHold = session.progressionHold {
                try? await session.authoredPlayback.releaseAuthoredProgressionHold(
                    progressionHold,
                    reason: reason
                )
            }
        }
        session = nil
        attachment = nil
        currentAuthoredSeed = nil
        currentAuthoredItemID = nil
        pendingHoldSurface = nil
        pendingHoldEndRequested = false
        presentedSeedIDs.removeAll(keepingCapacity: false)
        hudEventSink = nil
        print("[TuringLiveConversation] detached reason=\(reason)")
    }

    func canAcceptMicrophoneHold(surface: StoryInteractionSurfaceID) -> Bool {
        guard let session,
              session.activeTurnID == nil,
              waitingResponseTurnID == nil,
              pendingHoldSurface == nil,
              presentedSeedIDs[surface] != nil,
              activeResponseTurnID.flatMap({ turns[$0] })?.selectedSurface != surface else {
            return false
        }
        return true
    }

    func ownsMicrophoneHold(surface: StoryInteractionSurfaceID) -> Bool {
        if pendingHoldSurface == surface {
            return true
        }
        guard let turnID = session?.activeTurnID,
              let turn = turns[turnID] else {
            return false
        }
        return turn.selectedSurface == surface && turn.state == .dictating
    }

    func releaseReport(
        parentLease: StoryInteractionLease
    ) async -> TuringLiveConversationReleaseReport {
        let activeCompute = await computeAdmission.activeReservationCount()
        let parentLeaseStillCurrent: Bool
        do {
            try await arbiter.requireCurrent(parentLease)
            parentLeaseStillCurrent = true
        } catch {
            parentLeaseStillCurrent = false
        }
        let activeComputeTurns = turns.values.filter {
            $0.responseTask != nil && $0.allComputeFinished == false
        }.count
        let activePlayback = turns.values.filter {
            $0.responseStarted && $0.responseCompleted == false
        }.count
        let activeFiller = turns.values.filter {
            $0.initialFillerToken != nil
        }.count

        return TuringLiveConversationReleaseReport(
            activeSessionCount: session == nil ? 0 : 1,
            activeDictationCount: turns.values.filter {
                $0.state == .dictating
            }.count,
            activeComputeReservationCount: activeCompute,
            activeRenderSessionCount: activeComputeTurns,
            activeDecoderCallCount: activeComputeTurns > 0 ? 1 : 0,
            activeGeneratedPlaybackHandleCount: activePlayback,
            activeInitialFillerTokenCount: activeFiller,
            generatedRunDirectoryExists: turns.isEmpty == false,
            transientAudioResourceCount: activeFiller,
            activeHUDDeadlineCount: turns.values.filter {
                $0.questionTimer != nil
            }.count,
            activeChildPresentationCount: turns.values.filter {
                $0.childReleased == false
            }.count,
            activeProgressionHoldCount: session?.progressionHold == nil ? 0 : 1,
            parentLeaseStillCurrent: parentLeaseStillCurrent
        )
    }

    func microphoneHoldBegan(
        surface: StoryInteractionSurfaceID,
        source: String,
        dictation: TuringDictationCoordinator,
        legacyEventSink: (any TuringStoryWalkieInteractionEventSink)?
    ) {
        guard pendingHoldSurface == nil else { return }
        pendingHoldSurface = surface
        pendingHoldEndRequested = false
        self.hudEventSink = legacyEventSink as? any TuringLiveConversationHUDEventSink
        Task { [weak self] in
            await self?.beginTurn(
                surface: surface,
                source: source,
                dictation: dictation
            )
        }
    }

    func prepareForPrerecordingPreFiller(
        _ item: TuringAuthoredMediaItem
    ) async {
        guard let attachment,
              let catalogEntry = item.liveConversationCatalogEntry,
              let speaker = TuringConversationCharacterID(
                rawValue: item.speakerCharacterID
              ),
              catalogEntry.speakerCharacterID == speaker,
              catalogEntry.interactionSurface ==
                attachment.identity.interactionSurface else {
            return
        }

        let source = TuringSpokenPresentationSource.authored(
            prerecordingID: item.id,
            role: item.role
        )
        let run = TuringSpokenPresentationRunIdentity(
            flowIdentity: attachment.identity
        )

        // The PR-orientation interval is the first audible filler for an
        // authored point. Stage the same portrait that the PR will promote so
        // keep-alive motion and blinking are already visible while the device
        // static/tuning filler plays. Mouth playback remains at rest until the
        // actual authored-audio start supplies its pause-aware clock.
        await TuringAuthoredPresentationPreparationHub.shared.publish(
            TuringAuthoredPresentationPreparationHint(
                run: run,
                prerecordingID: item.id,
                role: item.role,
                speakerCharacterID: speaker,
                interactionSurface: catalogEntry.interactionSurface
            )
        )
        let request = TuringSpokenPresentationRevealRequest(
            id: UUID(),
            run: run,
            speakerCharacterID: speaker,
            interactionSurface: catalogEntry.interactionSurface,
            source: source,
            generatedSpeechFrameTrack: nil
        )
        let outcome = await TuringSpokenPresentationRevealHub.shared
            .requestReveal(
                request,
                timeout: Self.prerecordingPreFillerRevealTimeout
            )

        guard self.attachment?.identity.flowInstanceID ==
                attachment.identity.flowInstanceID else {
            return
        }
        print(
            "[MindEyeFiller] pre-PR portrait staged " +
                "itemID=\(item.id) speaker=\(speaker.rawValue) " +
                "surface=\(catalogEntry.interactionSurface.rawValue) " +
                "outcome=\(String(describing: outcome)) " +
                "motion=keepAlive blink=active mouth=rest " +
                "microphoneActivation=actualAuthoredMediaStart"
        )
    }

    func microphoneHoldEnded(
        surface: StoryInteractionSurfaceID,
        source: String
    ) {
        if pendingHoldSurface == surface {
            pendingHoldEndRequested = true
            return
        }
        Task { [weak self] in
            await self?.submitTurn(surface: surface, source: source)
        }
    }

    func emit(_ event: TuringConversationLifecycleEvent) async {
        let turnID: UUID
        switch event {
        case .foundationStarted(let id),
             .foundationCompleted(let id, _),
             .segmentPublished(let id, _),
             .segmentZeroPrepared(let id),
             .allTTSComputeFinished(let id, _, _),
             .responsePlaybackOwnerReady(let id, _),
             .responsePlaybackStarted(let id, _),
             .responsePlaybackCompleted(let id),
             .failed(let id, _, _):
            turnID = id
        }
        guard let turn = turns[turnID] else { return }

        switch event {
        case .foundationStarted:
            turn.state = .computing
        case .foundationCompleted:
            break
        case .segmentPublished:
            break
        case .segmentZeroPrepared:
            turn.segmentZeroPrepared = true
        case .allTTSComputeFinished:
            guard turn.allComputeFinished == false else { return }
            turn.allComputeFinished = true
            await computeAdmission.release(
                turn.computeToken,
                reason: "allTTSComputeFinished"
            )
            if turn.responseStarted {
                await exposeNextTurnMicrophonesIfPossible(for: turn)
            }
        case .responsePlaybackOwnerReady:
            break
        case .responsePlaybackStarted:
            turn.responseStarted = true
            turn.state = .playing
            activeResponseTurnID = turn.turnID
            if waitingResponseTurnID == turn.turnID {
                waitingResponseTurnID = nil
            }
            turn.questionTimer?.cancel()
            turn.questionTimer = nil
            if let initialFillerToken = turn.initialFillerToken {
                await prepareInitialFillerForSpokenPlayback(
                    turn,
                    reason: "responsePlaybackStarted"
                )
                if turn.initialFillerToken != nil {
                    switch initialFillerToken {
                    case .dadPhoto:
                        print(
                            "[TuringDadPhotoMusic] retained through TTS playback " +
                                "turnID=\(turn.turnID.uuidString)"
                        )
                    case .walkie(let token):
                        print(
                            "[TuringWalkieStatic] ambient retained through conversation playback " +
                                "turnID=\(turn.turnID.uuidString) " +
                                "ownerID=\(token.ownerID)"
                        )
                    case .crankRadio, .hamReceiver:
                        break
                    }
                }
            }
            publishHUD(
                turn: turn,
                kind: .responsePlaybackStarted(
                    question: turn.question ?? ""
                )
            )
            try? await arbiter.updateLiveConversationPresentation(
                childToken: turn.childToken,
                actions: [:],
                activities: [turn.selectedSurface: .conversationPlaying],
                childStillActive: true,
                reason: "responsePlaybackStarted"
            )
            if turn.allComputeFinished {
                await exposeNextTurnMicrophonesIfPossible(for: turn)
            }
        case .responsePlaybackCompleted:
            turn.responseCompleted = true
            turn.state = .completed
            await releaseInitialFillerIfNeeded(
                turn,
                reason: "responsePlaybackCompleted"
            )
            publishHUD(turn: turn, kind: .responsePlaybackFinished)
            if activeResponseTurnID == turn.turnID {
                activeResponseTurnID = nil
            }
            await finishTurnAndSession(turn, reason: "responsePlaybackCompleted")
        case .failed(_, let stage, let message):
            turn.state = .failed
            publishHUD(turn: turn, kind: .failed(message))
            await cancelTurn(
                turn,
                reason: "conversationFailed.\(stage)",
                publishFailure: false
            )
            await finishTurnAndSession(
                turn,
                reason: "conversationFailed.\(stage)",
                restoreCurrentAuthoredAvailability: true
            )
        }
    }

    func responsePlaybackOwnerReady(
        turnID: UUID,
        playback: any TuringFlowPlaybackControlling
    ) async {
        guard let turn = turns[turnID] else { return }
        turn.responsePlayback = playback
        if turn.coverCompleted {
            await playback.generatedPlaybackGateDidChange()
        }
    }

    func receivePlaybackLifecycleEvent(
        _ event: TuringFlowPlaybackLifecycleEvent
    ) async {
        guard let attachment,
              event.runID == attachment.identity.playbackRunID else { return }
        switch event {
        case .authoredMediaStarted(_, let item, _):
            await authoredMediaDidStart(item, attachment: attachment)
        case .authoredMediaCompleted(_, let itemID, _):
            await authoredMediaDidComplete(itemID: itemID)
        case .failed(_, let reason):
            await detach(reason: "authoredPlaybackFailed.\(reason)")
        case .authoredMediaPaused,
             .authoredMediaResumed,
             .generatedSegmentStarted,
             .generatedSegmentCompleted,
             .generatedPlaybackCompleted:
            break
        }
    }

    private func authoredMediaDidStart(
        _ item: TuringAuthoredMediaItem,
        attachment: Attachment
    ) async {
        guard item.liveConversationCatalogEntry != nil else {
            currentAuthoredItemID = item.id
            currentAuthoredSeed = nil
            return
        }
        do {
            if currentAuthoredItemID == item.id,
               let seed = currentAuthoredSeed,
               seed.authoredMediaItemID == item.id,
               let existingSession = session {
                let heldSession = try await ensureProgressionHold(
                    existingSession,
                    reason: "eligibleAuthoredMediaStarted.\(item.id)"
                )
                session = heldSession
                print(
                    "[TuringLiveConversation] pre-filler seed promoted to authored media " +
                        "itemID=\(item.id) seedID=\(seed.seedID.uuidString)"
                )
                return
            }
            try await installAuthoredAvailability(
                item: item,
                attachment: attachment,
                acquireProgressionHold: true,
                reason: "authoredMediaStarted"
            )
        } catch {
            print("[TuringLiveConversation] seed rejected itemID=\(item.id) error=\(error.localizedDescription)")
            await finishSessionIfIdle(reason: "seedResolutionFailed")
        }
    }

    private func authoredMediaDidComplete(itemID: String) async {
        guard itemID == currentAuthoredItemID else { return }
        currentAuthoredItemID = nil
        if let liveSession = session,
           liveSession.activeTurnID == nil {
            currentAuthoredSeed = nil
            if await restoreRetainedAvailabilityIfPossible(
                session: liveSession,
                reason: "authoredMediaCompletedWithoutQuestion"
            ) {
                return
            }
            presentedSeedIDs.removeAll(keepingCapacity: false)
            await finishSessionIfIdle(reason: "authoredMediaCompletedWithoutQuestion")
        }
    }

    private func beginTurn(
        surface: StoryInteractionSurfaceID,
        source: String,
        dictation: TuringDictationCoordinator
    ) async {
        guard var liveSession = session,
              liveSession.activeTurnID == nil,
              waitingResponseTurnID == nil,
              let expectedSeedID = presentedSeedIDs[surface],
              let attachment else {
            clearPendingHold(surface: surface)
            return
        }
        let turnID = UUID()
        var childToken: StoryLiveConversationChildToken?
        var computeToken: TuringLiveConversationComputeAdmission.Token?
        var receipt: TuringSpokenCoverPauseReceipt?
        var pausedCoverPlayback: (any TuringSpokenCoverControlling)?
        do {
            let seed = try await arbiter.recaptureLatchedConversationSeed(
                surface: surface,
                expectedSeedID: expectedSeedID
            )
            childToken = try await arbiter.claimLiveConversationChild(
                parentLease: liveSession.parentLease,
                sessionID: liveSession.sessionID,
                turnID: turnID,
                selectedSurface: surface,
                reason: source
            )
            liveSession = try await ensureProgressionHold(
                liveSession,
                reason: "microphoneSelected.\(surface.rawValue)"
            )
            session = liveSession
            computeToken = try await computeAdmission.reserve(
                sessionID: liveSession.sessionID,
                turnID: turnID
            )
            let coverPlayback: any TuringSpokenCoverControlling
            if let activeResponseTurnID,
               let activeResponse = turns[activeResponseTurnID],
               let responsePlayback = activeResponse.responsePlayback as?
                    any TuringSpokenCoverControlling {
                coverPlayback = responsePlayback
                waitingResponseTurnID = turnID
            } else {
                coverPlayback = attachment.spokenPlayback
            }
            pausedCoverPlayback = coverPlayback
            receipt = try await coverPlayback.pauseCurrentSpokenMedia(
                interruptionID: turnID
            )
            guard let childToken, let computeToken, let receipt else { return }
            let gate = TuringConversationPlaybackStartGate()
            let turn = TuringLiveConversationTurn(
                turnID: turnID,
                selectedSurface: surface,
                seed: seed,
                computeToken: computeToken,
                childToken: childToken,
                coverReceipt: receipt,
                coverPlayback: coverPlayback,
                playbackGate: gate,
                dictation: dictation,
                previousDictationEventHandler: dictation.onEvent
            )
            turns[turnID] = turn
            liveSession.activeTurnID = turnID
            session = liveSession
            dictation.onEvent = { [weak self] event in
                self?.consumeDictationEvent(event, turnID: turnID)
            }
            await dictation.beginHoldToRecord()
            guard dictation.isRecording else {
                clearPendingHold(surface: surface)
                await cancelTurn(turn, reason: "dictationDidNotStart", publishFailure: true)
                await finishTurnAndSession(
                    turn,
                    reason: "dictationDidNotStart",
                    restoreCurrentAuthoredAvailability: true
                )
                return
            }
            let submitImmediately = pendingHoldEndRequested
            clearPendingHold(surface: surface)
            print("[TuringLiveConversation] dictation started turnID=\(turnID.uuidString) surface=\(surface.rawValue)")
            if submitImmediately {
                await submitTurn(
                    surface: surface,
                    source: "queuedHoldEnd.\(source)"
                )
            }
        } catch {
            clearPendingHold(surface: surface)
            if waitingResponseTurnID == turnID {
                waitingResponseTurnID = nil
            }
            if let receipt, let pausedCoverPlayback {
                try? await pausedCoverPlayback.resumeCurrentSpokenMedia(receipt)
            }
            if let computeToken {
                await computeAdmission.release(computeToken, reason: "beginTurnFailed")
            }
            if let childToken {
                try? await arbiter.updateLiveConversationPresentation(
                    childToken: childToken,
                    actions: presentedSeedIDs.mapValues { _ in .microphone },
                    activities: [surface: .authoredPlaying],
                    childStillActive: false,
                    reason: "beginTurnFailed"
                )
            }
            print("[TuringLiveConversation] begin failed error=\(error.localizedDescription)")
        }
    }

    private func clearPendingHold(surface: StoryInteractionSurfaceID) {
        guard pendingHoldSurface == surface else { return }
        pendingHoldSurface = nil
        pendingHoldEndRequested = false
    }

    private func submitTurn(
        surface: StoryInteractionSurfaceID,
        source: String
    ) async {
        guard let turnID = session?.activeTurnID,
              let turn = turns[turnID],
              turn.selectedSurface == surface,
              turn.state == .dictating,
              let liveSession = session else { return }
        do {
            let transcript = try await turn.dictation.endHoldToSend()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard transcript.isEmpty == false else {
                throw TuringRuntimeError.invalidConfig("Dictation was empty.")
            }
            turn.question = transcript
            turn.state = .submitted
            publishHUD(turn: turn, kind: .questionSubmitted(transcript))
            if turn.selectedSurface == .walkie {
                await beginInitialFillerIfNeeded(turn)
            }
            turn.questionTimer = Task { [weak self, weak turn] in
                try? await Task.sleep(for: Self.submittedQuestionHold)
                guard Task.isCancelled == false, let self, let turn,
                      turn.responseStarted == false else { return }
                self.publishHUD(turn: turn, kind: .questionDisplayExpired)
                try? await self.arbiter.updateLiveConversationPresentation(
                    childToken: turn.childToken,
                    actions: [:],
                    activities: [turn.selectedSurface: .processingEllipsis],
                    childStillActive: true,
                    reason: "questionDisplayExpired"
                )
            }
            turn.coverWaiter = Task { [weak self, weak turn] in
                guard let self, let turn else { return }
                let coverCompleted = await self.resumeAndWaitForSpokenCover(turn)
                guard Task.isCancelled == false, coverCompleted else { return }
                await self.coverDidComplete(turnID: turn.turnID)
            }
            turn.responseTask = Task { [weak self, weak turn] in
                guard let self, let turn else { return }
                let result = await TuringFlowConversationRunner.run(
                    request: TuringFlowConversationRequest(
                        conversationRunID: turn.turnID,
                        characterID: turn.seed.characterID,
                        outputRoute: turn.seed.outputRoute,
                        conversationKey: turn.seed.conversationKey,
                        playerDictation: transcript,
                        interactionLease: liveSession.parentLease,
                        interactionSurface: turn.selectedSurface,
                        immutableSeed: turn.seed,
                        leasePolicy: .borrowedFromAuthoredFlow(
                            hostFlowSequenceID: liveSession.parentFlowSequenceID,
                            hostFlowInstanceID: liveSession.parentFlowInstanceID,
                            parentLeaseID: liveSession.parentLease.id
                        ),
                        progressionPolicy: .neverAdvanceStory,
                        completionPresentation: .callerOwned,
                        playbackConfiguration: TuringGeneratedPlaybackConfiguration(
                            startGate: turn.playbackGate,
                            initialGapOwnership: .externallyOwned
                        ),
                        lifecycleSink: self
                    )
                )
                guard result.succeeded else {
                    await self.handleRunnerFailure(
                        turnID: turn.turnID,
                        message: result.pickerStatus
                    )
                    return
                }
            }
            print("[TuringLiveConversation] question submitted turnID=\(turnID.uuidString) source=\(source)")
        } catch {
            await cancelTurn(turn, reason: "dictationSubmissionFailed", publishFailure: true)
            await finishTurnAndSession(
                turn,
                reason: "dictationSubmissionFailed",
                restoreCurrentAuthoredAvailability: true
            )
        }
    }

    private func resumeAndWaitForSpokenCover(
        _ turn: TuringLiveConversationTurn
    ) async -> Bool {
        if turn.coverReceipt.result == .paused,
           turn.initialFillerToken?
                .mustEndBeforeSpokenCoverResumes == true {
            try? await Task.sleep(for: Self.submittedQuestionHold)
            guard Task.isCancelled == false else { return false }
            await prepareInitialFillerForSpokenPlayback(
                turn,
                reason: "spokenCoverResuming"
            )
            print(
                "[TuringLiveConversation] initial filler ended before " +
                    "spoken cover resumed turnID=\(turn.turnID.uuidString) " +
                    "surface=\(turn.selectedSurface.rawValue)"
            )
        }

        do {
            try await turn.coverPlayback.resumeCurrentSpokenMedia(
                turn.coverReceipt
            )
            try await turn.coverPlayback.waitUntilSpokenMediaCompletes(
                turn.coverReceipt
            )
            return true
        } catch {
            guard Task.isCancelled == false else { return false }
            await handleRunnerFailure(
                turnID: turn.turnID,
                message: "Device operation failed."
            )
            return false
        }
    }

    private func coverDidComplete(turnID: UUID) async {
        guard let turn = turns[turnID], turn.coverCompleted == false else { return }
        turn.coverCompleted = true
        turn.state = .waitingForCover
        if turn.selectedSurface == .dadFrame || turn.segmentZeroPrepared == false {
            await beginInitialFillerIfNeeded(turn)
        }
        await turn.playbackGate.open()
        await turn.responsePlayback?.generatedPlaybackGateDidChange()
        print("[TuringLiveConversation] cover completed gate opened turnID=\(turnID.uuidString) segmentZeroPrepared=\(turn.segmentZeroPrepared)")
    }

    private func beginInitialFillerIfNeeded(
        _ turn: TuringLiveConversationTurn
    ) async {
        guard turn.initialFillerToken == nil else { return }
        turn.initialFillerToken = await filler.begin(
            request: TuringLiveConversationInitialFillerRequest(
                ownerID: "live.\(turn.turnID.uuidString)",
                surface: turn.selectedSurface,
                seed: turn.seed
            )
        )
    }

    private func handleRunnerFailure(turnID: UUID, message: String) async {
        guard let turn = turns[turnID], turn.state != .completed else { return }
        publishHUD(turn: turn, kind: .failed(message))
        await cancelTurn(turn, reason: "runnerFailed", publishFailure: false)
        await finishTurnAndSession(
            turn,
            reason: "runnerFailed",
            restoreCurrentAuthoredAvailability: true
        )
    }

    private func cancelTurn(
        _ turn: TuringLiveConversationTurn,
        reason: String,
        publishFailure: Bool
    ) async {
        turn.questionTimer?.cancel()
        turn.coverWaiter?.cancel()
        turn.responseTask?.cancel()
        turn.questionTimer = nil
        turn.coverWaiter = nil
        turn.responseTask = nil
        await turn.dictation.cancel(reason: reason)
        restoreDictationEventHandler(for: turn)
        await turn.playbackGate.cancel(reason: reason)
        if let responsePlayback = turn.responsePlayback {
            await responsePlayback.runCancelled(reason: reason)
        }
        await releaseInitialFillerIfNeeded(turn, reason: reason)
        try? await turn.coverPlayback.resumeCurrentSpokenMedia(turn.coverReceipt)
        if turn.allComputeFinished == false {
            turn.allComputeFinished = true
            await computeAdmission.release(turn.computeToken, reason: reason)
        }
        turn.state = .cancelled
        if publishFailure {
            publishHUD(turn: turn, kind: .failed("Device operation failed."))
        }
    }

    private func releaseInitialFillerIfNeeded(
        _ turn: TuringLiveConversationTurn,
        reason: String
    ) async {
        guard let token = turn.initialFillerToken else { return }
        turn.initialFillerToken = nil
        await filler.end(token, reason: reason)
    }

    private func prepareInitialFillerForSpokenPlayback(
        _ turn: TuringLiveConversationTurn,
        reason: String
    ) async {
        guard let token = turn.initialFillerToken,
              token.mustEndBeforeSpokenCoverResumes else {
            return
        }
        await filler.responsePlaybackWillStart(token, reason: reason)
        if token.endsWhenResponsePlaybackStarts {
            turn.initialFillerToken = nil
        }
    }

    private func finishTurnAndSession(
        _ turn: TuringLiveConversationTurn,
        reason: String,
        restoreCurrentAuthoredAvailability: Bool = false
    ) async {
        guard var liveSession = session,
              turns[turn.turnID] != nil else { return }
        if turn.childReleased == false {
            try? await arbiter.updateLiveConversationPresentation(
                childToken: turn.childToken,
                actions: [:],
                activities: [:],
                childStillActive: false,
                reason: reason
            )
            turn.childReleased = true
        }
        restoreDictationEventHandler(for: turn)
        turns.removeValue(forKey: turn.turnID)
        if liveSession.activeTurnID == turn.turnID {
            liveSession.activeTurnID = nil
        }
        if activeResponseTurnID == turn.turnID {
            activeResponseTurnID = nil
        }
        if waitingResponseTurnID == turn.turnID {
            waitingResponseTurnID = nil
        }
        session = liveSession
        if turns.isEmpty {
            if restoreCurrentAuthoredAvailability,
               await restoreAuthoredAvailabilityAfterOptionalFailure(
                    session: liveSession,
                    seed: turn.seed,
                    reason: reason
               ) {
                return
            }
            currentAuthoredSeed = nil
            currentAuthoredItemID = nil
            if await restoreRetainedAvailabilityIfPossible(
                session: liveSession,
                reason: reason
            ) {
                return
            }
            presentedSeedIDs.removeAll(keepingCapacity: false)
            await finishSessionIfIdle(reason: reason)
        } else if let activeResponseTurnID,
                  let activeResponse = turns[activeResponseTurnID],
                  activeResponse.allComputeFinished,
                  waitingResponseTurnID == nil {
            await exposeNextTurnMicrophonesIfPossible(for: activeResponse)
        }
    }

    private func restoreAuthoredAvailabilityAfterOptionalFailure(
        session liveSession: TuringLiveConversationSession,
        seed: TuringLiveConversationSeed,
        reason: String
    ) async -> Bool {
        let stablePolicy = await arbiter.currentStableInteractionPolicy()
        let snapshot = await arbiter.currentLatchedConversationSeedSnapshot(
            allowedSurfaces: stablePolicy.allowedTuringSurfaces
        )
        guard snapshot.seedsBySurface[seed.interactionSurface]?
                .seedID == seed.seedID else {
            return false
        }
        if await restoreRetainedAvailabilityIfPossible(
            session: liveSession,
            reason: "optionalFailureRecovered.\(reason)"
        ) {
            print(
                "[TuringLiveConversation] optional failure recovered " +
                    "itemID=\(seed.authoredMediaItemID) " +
                    "surface=\(seed.interactionSurface.rawValue) " +
                    "reason=\(reason)"
            )
            return true
        }
        print(
            "[TuringLiveConversation] optional failure recovery failed " +
                "itemID=\(seed.authoredMediaItemID) reason=\(reason)"
        )
        return false
    }

    private func restoreRetainedAvailabilityIfPossible(
        session liveSession: TuringLiveConversationSession,
        reason: String
    ) async -> Bool {
        let stablePolicy = await arbiter.currentStableInteractionPolicy()
        let snapshot = await arbiter.currentLatchedConversationSeedSnapshot(
            allowedSurfaces: stablePolicy.allowedTuringSurfaces
        )
        guard snapshot.seedsBySurface.isEmpty == false else {
            return false
        }

        do {
            try await arbiter.installLiveConversationAvailability(
                parentLease: liveSession.parentLease,
                sessionID: liveSession.sessionID,
                generation: liveSession.generation,
                eligibleSeeds: snapshot,
                authoredActivitySurface: nil,
                reason: "retainedAvailability.\(reason)"
            )
            presentedSeedIDs = snapshot.seedsBySurface.mapValues(\.seedID)

            if let progressionHold = liveSession.progressionHold {
                var releasedSession = liveSession
                releasedSession.progressionHold = nil
                session = releasedSession
                do {
                    try await liveSession.authoredPlayback
                        .releaseAuthoredProgressionHold(
                            progressionHold,
                            reason: reason
                        )
                } catch {
                    session = liveSession
                    throw error
                }
            } else {
                session = liveSession
            }
            print(
                "[TuringLiveConversation] retained microphones restored " +
                    "surfaces=\(snapshot.seedsBySurface.keys.map(\.rawValue).sorted()) " +
                    "reason=\(reason)"
            )
            return true
        } catch {
            print(
                "[TuringLiveConversation] retained microphone restore failed " +
                    "reason=\(reason) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private func replaceAttachmentPreservingRetainedAvailability(
        parentSequenceID: UUID,
        parentLease: StoryInteractionLease,
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        playback: any TuringFlowPlaybackControlling,
        spokenPlayback: any TuringSpokenCoverControlling,
        previousSession: TuringLiveConversationSession
    ) async throws {
        await attachment?.playback.setPlaybackLifecycleSink(nil)
        generation &+= 1
        let microphoneGeneration =
            await arbiter.currentConversationMicrophoneGeneration()
        let replacement = Attachment(
            parentSequenceID: parentSequenceID,
            parentLease: parentLease,
            descriptor: descriptor,
            identity: identity,
            playback: playback,
            spokenPlayback: spokenPlayback,
            microphoneGeneration: microphoneGeneration
        )
        attachment = replacement
        await playback.setPlaybackLifecycleSink(self)

        let stablePolicy = await arbiter.currentStableInteractionPolicy()
        let snapshot = await arbiter.currentLatchedConversationSeedSnapshot(
            allowedSurfaces: stablePolicy.allowedTuringSurfaces
        )
        let replacementSession = TuringLiveConversationSession(
            sessionID: previousSession.sessionID,
            generation: generation,
            parentFlowSequenceID: parentSequenceID,
            parentFlowInstanceID: identity.flowInstanceID,
            parentPlaybackRunID: identity.playbackRunID,
            parentLease: parentLease,
            authoredPlayback: playback,
            progressionHold: nil,
            activeTurnID: nil
        )
        session = replacementSession
        currentAuthoredSeed = nil
        currentAuthoredItemID = nil
        presentedSeedIDs = snapshot.seedsBySurface.mapValues(\.seedID)
        do {
            try await arbiter.installLiveConversationAvailability(
                parentLease: parentLease,
                sessionID: replacementSession.sessionID,
                generation: replacementSession.generation,
                eligibleSeeds: snapshot,
                authoredActivitySurface: nil,
                reason: "attachmentReplacedWithRetainedAvailability"
            )
        } catch {
            await playback.setPlaybackLifecycleSink(nil)
            attachment = nil
            session = nil
            presentedSeedIDs.removeAll(keepingCapacity: false)
            throw error
        }
        print(
            "[TuringLiveConversation] attachment replaced without hiding retained " +
                "microphones sequenceID=\(parentSequenceID.uuidString) " +
                "flowInstanceID=\(identity.flowInstanceID.uuidString)"
        )
    }

    private func finishSessionIfIdle(reason: String) async {
        guard let liveSession = session,
              liveSession.activeTurnID == nil,
              turns.isEmpty else { return }
        await arbiter.removeLiveConversationSession(
            parentLease: liveSession.parentLease,
            sessionID: liveSession.sessionID,
            generation: liveSession.generation,
            reason: reason
        )
        if let progressionHold = liveSession.progressionHold {
            try? await liveSession.authoredPlayback.releaseAuthoredProgressionHold(
                progressionHold,
                reason: reason
            )
        }
        session = nil
        hudEventSink = nil
    }

    private func installAuthoredAvailability(
        item: TuringAuthoredMediaItem,
        attachment: Attachment,
        acquireProgressionHold: Bool,
        reason: String
    ) async throws {
        guard let entry = item.liveConversationCatalogEntry else {
            return
        }
        let seed = try await TuringConversationMicrophoneActivationCoordinator
            .shared.authoredMediaStarted(
            entry: entry,
            item: item,
            descriptor: attachment.descriptor,
            parentSequenceID: attachment.parentSequenceID,
            identity: attachment.identity,
            expectedMicrophoneGeneration: attachment.microphoneGeneration
        )
        currentAuthoredItemID = item.id
        currentAuthoredSeed = seed

        var liveSession: TuringLiveConversationSession
        if let session {
            liveSession = session
        } else {
            liveSession = TuringLiveConversationSession(
                sessionID: UUID(),
                generation: generation,
                parentFlowSequenceID: attachment.parentSequenceID,
                parentFlowInstanceID: attachment.identity.flowInstanceID,
                parentPlaybackRunID: attachment.identity.playbackRunID,
                parentLease: attachment.parentLease,
                authoredPlayback: attachment.playback,
                progressionHold: nil,
                activeTurnID: nil
            )
        }
        if acquireProgressionHold {
            liveSession = try await ensureProgressionHold(
                liveSession,
                reason: "\(reason).\(item.id)"
            )
        }
        session = liveSession

        let stablePolicy = await arbiter.currentStableInteractionPolicy()
        let snapshot = await arbiter.currentLatchedConversationSeedSnapshot(
            allowedSurfaces: stablePolicy.allowedTuringSurfaces
        )
        presentedSeedIDs = snapshot.seedsBySurface.mapValues(\.seedID)
        try await arbiter.installLiveConversationAvailability(
            parentLease: liveSession.parentLease,
            sessionID: liveSession.sessionID,
            generation: liveSession.generation,
            eligibleSeeds: snapshot,
            authoredActivitySurface: seed.interactionSurface,
            reason: "\(reason).\(item.id)"
        )
        print(
            "[TuringLiveConversation] seed installed " +
                "itemID=\(item.id) seedID=\(seed.seedID.uuidString) " +
                "phase=\(reason)"
        )
    }

    private func ensureProgressionHold(
        _ liveSession: TuringLiveConversationSession,
        reason: String
    ) async throws -> TuringLiveConversationSession {
        guard liveSession.progressionHold == nil else {
            return liveSession
        }
        var updated = liveSession
        updated.progressionHold = try await liveSession.authoredPlayback
            .acquireAuthoredProgressionHold(
                liveSessionID: liveSession.sessionID,
                reason: reason
            )
        return updated
    }

    private func exposeNextTurnMicrophonesIfPossible(
        for activeResponse: TuringLiveConversationTurn
    ) async {
        guard var liveSession = session,
              activeResponse.responseStarted,
              activeResponse.responseCompleted == false,
              activeResponse.allComputeFinished,
              activeResponseTurnID == activeResponse.turnID,
              waitingResponseTurnID == nil else {
            return
        }
        let stablePolicy = await arbiter.currentStableInteractionPolicy()
        let snapshot = await arbiter.currentLatchedConversationSeedSnapshot(
            allowedSurfaces: stablePolicy.allowedTuringSurfaces
        )
        var eligible = snapshot.seedsBySurface
        eligible.removeValue(forKey: activeResponse.selectedSurface)
        presentedSeedIDs = eligible.mapValues(\.seedID)
        let actions = presentedSeedIDs.mapValues { _ in
            StoryTuringActionPresentation.microphone
        }
        if activeResponse.childReleased == false {
            do {
                try await arbiter.updateLiveConversationPresentation(
                    childToken: activeResponse.childToken,
                    actions: actions,
                    activities: [
                        activeResponse.selectedSurface: .conversationPlaying
                    ],
                    childStillActive: false,
                    reason: "responseComputeFinished"
                )
                activeResponse.childReleased = true
            } catch {
                print(
                    "[TuringLiveConversation] next-turn presentation failed " +
                        "turnID=\(activeResponse.turnID.uuidString) " +
                        "error=\(error.localizedDescription)"
                )
                return
            }
        }
        if liveSession.activeTurnID == activeResponse.turnID {
            liveSession.activeTurnID = nil
            session = liveSession
        }
        print(
            "[TuringLiveConversation] next-turn microphones exposed " +
                "coverTurnID=\(activeResponse.turnID.uuidString) " +
                "surfaces=\(presentedSeedIDs.keys.map(\.rawValue).sorted())"
        )
    }

    private func publishHUD(
        turn: TuringLiveConversationTurn,
        kind: TuringLiveConversationHUDEvent.Kind
    ) {
        guard let session else { return }
        hudEventSink?.publishLiveConversationHUDEvent(
            TuringLiveConversationHUDEvent(
                sessionID: session.sessionID,
                turnID: turn.turnID,
                generation: session.generation,
                surface: turn.selectedSurface,
                kind: kind
            )
        )
    }

    private func consumeDictationEvent(
        _ event: TuringDictationEvent,
        turnID: UUID
    ) {
        guard let turn = turns[turnID] else { return }
        switch event {
        case .recordingStarted:
            publishHUD(turn: turn, kind: .listeningStarted)
        case .partialTranscript(let text):
            publishHUD(turn: turn, kind: .partialTranscript(text))
        case .failed(let message):
            publishHUD(turn: turn, kind: .failed(message))
        case .cancelled, .finalTranscript, .processingStarted,
             .questionDisplayExpired, .responseAudioStarted(_),
             .responseSegmentZeroReady,
             .responseAudioFinished, .responseFailed:
            break
        }
    }

    private func restoreDictationEventHandler(
        for turn: TuringLiveConversationTurn
    ) {
        guard turn.dictationEventHandlerRestored == false else { return }
        turn.dictation.onEvent = turn.previousDictationEventHandler
        turn.dictationEventHandlerRestored = true
    }
}
