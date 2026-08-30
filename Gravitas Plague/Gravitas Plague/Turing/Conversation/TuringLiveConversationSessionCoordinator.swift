import AVFoundation
import Foundation
import TuringQwenNative

nonisolated enum TuringPrerecordingMicrophoneCTAPolicy {
    static let fullyDesaturatedRemainingSeconds = 20.0
    static let maximumTransitionSteps = 100
    static let maximumUpdatesPerSecond = 20.0

    static func transitionDuration(
        prerecordingDurationSeconds duration: Double
    ) -> Double {
        max(0, duration - fullyDesaturatedRemainingSeconds)
    }

    static func transitionStepCount(
        prerecordingDurationSeconds duration: Double
    ) -> Int {
        let transition = transitionDuration(
            prerecordingDurationSeconds: duration
        )
        guard transition > 0 else { return 0 }
        return min(
            maximumTransitionSteps,
            max(1, Int(ceil(transition * maximumUpdatesPerSecond)))
        )
    }

    static func saturationStep(
        prerecordingDurationSeconds duration: Double,
        elapsedPlaybackSeconds elapsed: Double,
        stepCount: Int
    ) -> Int {
        let transition = transitionDuration(
            prerecordingDurationSeconds: duration
        )
        guard transition > 0, stepCount > 0 else { return 0 }
        let progress = min(1, max(0, elapsed / transition))
        let completedSteps = min(
            stepCount,
            Int(floor(progress * Double(stepCount)))
        )
        return stepCount - completedSteps
    }

    static func saturation(
        prerecordingDurationSeconds duration: Double,
        elapsedPlaybackSeconds elapsed: Double,
        stepCount: Int
    ) -> Float {
        guard stepCount > 0 else { return 0 }
        return Float(saturationStep(
            prerecordingDurationSeconds: duration,
            elapsedPlaybackSeconds: elapsed,
            stepCount: stepCount
        )) / Float(stepCount)
    }
}

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

    private struct MicrophoneCTAPlaybackState {
        let generation: UInt64
        let itemID: String
        let surfaces: Set<StoryInteractionSurfaceID>
        var prerecordingDurationSeconds: Double?
        var transitionStepCount: Int
        var lastPublishedSaturationStep: Int?
        var accumulatedPlaybackSeconds: Double
        var runningSince: ContinuousClock.Instant?
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
    private var actualAuthoredMediaStartedItemID: String?
    private var currentAuthoredSeed: TuringLiveConversationSeed?
    private var currentAuthoredItemID: String?
    private var completedAuthoredMediaItemIDs: Set<String> = []
    private var authoredMediaCompletionWaiters:
        [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]
    private var microphoneCTAGeneration: UInt64 = 0
    private var microphoneCTAState: MicrophoneCTAPlaybackState?
    private var microphoneCTADurationTasks: [String: Task<Void, Never>] = [:]
    private var authoredMediaDurationSeconds: [String: Double] = [:]
    private var microphoneCTATimerTask: Task<Void, Never>?
    private var desaturatedMicrophoneSurfaces:
        Set<StoryInteractionSurfaceID> = []
    private var pendingHoldSurface: StoryInteractionSurfaceID?
    private var pendingHoldEndRequested = false
    private weak var hudEventSink: (any TuringLiveConversationHUDEventSink)?
    private var recoveryAvailability:
        TuringQwenNativeRecoveryAvailability = .ready(generation: 1)
    private var recoveryAvailabilityTask: Task<Void, Never>?

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
            await refreshRecoveryAvailabilityAndObserve()
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
        await refreshRecoveryAvailabilityAndObserve()
        print("[TuringLiveConversation] attached sequenceID=\(parentSequenceID.uuidString) flowInstanceID=\(identity.flowInstanceID.uuidString)")
    }

    func authoredFlowDidComplete(reason: String) async {
        guard let liveSession = session,
              liveSession.activeTurnID == nil,
              turns.isEmpty else {
            return
        }
        actualAuthoredMediaStartedItemID = nil
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
        cancelMicrophoneCTA(reason: "detach.\(reason)")
        resumeAllAuthoredMediaCompletionWaiters(completed: false)
        completedAuthoredMediaItemIDs.removeAll(keepingCapacity: false)
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
        actualAuthoredMediaStartedItemID = nil
        pendingHoldSurface = nil
        pendingHoldEndRequested = false
        presentedSeedIDs.removeAll(keepingCapacity: false)
        hudEventSink = nil
        recoveryAvailabilityTask?.cancel()
        recoveryAvailabilityTask = nil
        print("[TuringLiveConversation] detached reason=\(reason)")
    }

    func canAcceptMicrophoneHold(surface: StoryInteractionSurfaceID) -> Bool {
        guard case .ready = recoveryAvailability,
              let session,
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
        guard Task.isCancelled == false,
              actualAuthoredMediaStartedItemID != item.id,
              let attachment,
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
        completedAuthoredMediaItemIDs.remove(item.id)
        preloadMicrophoneCTADuration(for: item)
        let run = TuringSpokenPresentationRunIdentity(
            flowIdentity: attachment.identity
        )
        // Start microphone installation alongside the visual path. It must not
        // sit in front of the two-to-five-second orientation filler: on device,
        // that was long enough for walkie static/radio tuning/Dad score to end
        // before Mind's Eye ever received its reveal request.
        async let microphoneContext = stagePrerecordingPreFillerMicrophones(
            item: item,
            catalogEntry: catalogEntry,
            attachment: attachment
        )

        // The PR-orientation interval is the first audible filler for an
        // authored point. Immediately stage the same portrait that the PR will
        // promote so keep-alive motion and blinking remain visible for the
        // entire device filler. These fillers are non-speech device audio, so
        // the mouth correctly stays at rest until authored speech actually
        // starts with its pause-aware playback clock.
        await TuringAuthoredPresentationPreparationHub.shared.publish(
            TuringAuthoredPresentationPreparationHint(
                run: run,
                prerecordingID: item.id,
                role: item.role,
                speakerCharacterID: speaker,
                interactionSurface: catalogEntry.interactionSurface
            )
        )
        guard Task.isCancelled == false,
              actualAuthoredMediaStartedItemID != item.id else {
            return
        }
        let request = TuringSpokenPresentationRevealRequest(
            id: UUID(),
            run: run,
            speakerCharacterID: speaker,
            interactionSurface: catalogEntry.interactionSurface,
            source: source,
            generatedSpeechFrameTrack: nil
        )
        print(
            "[MindEyeFiller] pre-PR device filler visual requested " +
                "itemID=\(item.id) speaker=\(speaker.rawValue) " +
                "surface=\(catalogEntry.interactionSurface.rawValue) " +
                "authoredPlaybackBlocked=false"
        )
        let outcome = await TuringSpokenPresentationRevealHub.shared
            .requestReveal(
                request,
                timeout: Self.prerecordingPreFillerRevealTimeout
            )
        let resolvedMicrophoneContext = await microphoneContext

        guard self.attachment?.identity.flowInstanceID ==
                attachment.identity.flowInstanceID else {
            return
        }
        let stagedIdentity =
            "itemID=\(item.id) speaker=\(speaker.rawValue)"
        let stagedSurface =
            "surface=\(catalogEntry.interactionSurface.rawValue)"
        let stagedOutcome =
            "outcome=\(String(describing: outcome))"
        print(
            "[MindEyeFiller] pre-PR portrait staged " +
                "\(stagedIdentity) \(stagedSurface) \(stagedOutcome) " +
                "orientationAudio=deviceFiller " +
                "motion=keepAlive blink=active mouth=restNonSpeech " +
                "microphoneContext=\(resolvedMicrophoneContext) " +
                "microphoneActionActivation=preFillerSelectable"
        )
    }

    private func stagePrerecordingPreFillerMicrophones(
        item: TuringAuthoredMediaItem,
        catalogEntry: TuringLiveConversationCatalog.Entry,
        attachment: Attachment
    ) async -> String {
        // Pre-filler installs a real selectable microphone for the upcoming
        // PromptVoice seed. Selecting it starts dictation and compute now,
        // without acquiring a progression hold that could delay PR start.
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
            session = liveSession
        }

        do {
            let activation = try await
                TuringConversationMicrophoneActivationCoordinator.shared
                    .authoredMediaStarted(
                        entry: catalogEntry,
                        item: item,
                        descriptor: attachment.descriptor,
                        parentSequenceID: attachment.parentSequenceID,
                        identity: attachment.identity,
                        expectedMicrophoneGeneration:
                            attachment.microphoneGeneration,
                        parentLease: liveSession.parentLease,
                        liveSessionID: liveSession.sessionID,
                        livePresentationGeneration: liveSession.generation,
                        activationPhase: "preFillerUpcomingPromptVoice"
            )
            guard actualAuthoredMediaStartedItemID != item.id else {
                return "actualAuthoredMediaAlreadyStarted"
            }
            currentAuthoredItemID = item.id
            currentAuthoredSeed = activation.seed
            presentedSeedIDs = activation.eligibleSeeds.seedsBySurface
                .mapValues(\.seedID)
            desaturatedMicrophoneSurfaces.subtract(
                presentedSeedIDs.keys
            )
            print(
                "[TuringLiveConversation] pre-PR microphones staged " +
                    "itemID=\(item.id) " +
                    "surface=\(catalogEntry.interactionSurface.rawValue) " +
                    "context=upcomingPromptVoice " +
                    "selectable=true computeAhead=true progressionHold=false " +
                    "seedID=\(activation.seed.seedID.uuidString) " +
                    "selectedMomentID=" +
                    "\(activation.seed.targetContext.selectedMomentID) " +
                    "voicePromptID=\(activation.seed.voicePromptID)"
            )
            return "upcomingPromptVoice"
        } catch {
            print(
                "[TuringLiveConversation] pre-PR microphone staging failed " +
                    "itemID=\(item.id) " +
                    "error=\(error.localizedDescription)"
            )
            return "unavailable"
        }
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
        case .authoredMediaPaused(_, let itemID, _, _):
            await pauseMicrophoneCTA(itemID: itemID)
        case .authoredMediaResumed(_, let itemID, _, _):
            await resumeMicrophoneCTA(itemID: itemID)
        case .authoredMediaCompleted(_, let itemID, _):
            await authoredMediaDidComplete(itemID: itemID)
        case .failed(_, let reason):
            await detach(reason: "authoredPlaybackFailed.\(reason)")
        case .generatedSegmentStarted,
             .generatedSegmentCompleted,
             .generatedPlaybackCompleted:
            break
        }
    }

    private func authoredMediaDidStart(
        _ item: TuringAuthoredMediaItem,
        attachment: Attachment
    ) async {
        actualAuthoredMediaStartedItemID = item.id
        completedAuthoredMediaItemIDs.remove(item.id)
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
                await beginMicrophoneCTA(for: item)
                let heldSession = try await ensureProgressionHold(
                    existingSession,
                    reason: "eligibleAuthoredMediaStarted.\(item.id)"
                )
                session = heldSession
                await pauseAuthoredMediaForActivePrePRDictationIfNeeded(
                    itemID: item.id,
                    attachment: attachment
                )
                print(
                    "[TuringLiveConversation] pre-filler seed promoted to authored media " +
                        "itemID=\(item.id) seedID=\(seed.seedID.uuidString) " +
                        "microphoneContext=currentPromptVoice"
                )
                return
            }
            try await installAuthoredAvailability(
                item: item,
                attachment: attachment,
                acquireProgressionHold: true,
                reason: "authoredMediaStarted"
            )
            await beginMicrophoneCTA(for: item)
        } catch {
            print("[TuringLiveConversation] seed rejected itemID=\(item.id) error=\(error.localizedDescription)")
            await finishSessionIfIdle(reason: "seedResolutionFailed")
        }
    }

    private func authoredMediaDidComplete(itemID: String) async {
        markAuthoredMediaCompleted(itemID: itemID)
        await completeMicrophoneCTA(itemID: itemID)
        if actualAuthoredMediaStartedItemID == itemID {
            actualAuthoredMediaStartedItemID = nil
        }
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

    private func pauseAuthoredMediaForActivePrePRDictationIfNeeded(
        itemID: String,
        attachment: Attachment
    ) async {
        guard let activeTurnID = session?.activeTurnID,
              let turn = turns[activeTurnID],
              turn.seed.authoredMediaItemID == itemID,
              turn.state == .dictating,
              turn.coverReceipt.handle == nil else {
            return
        }
        do {
            turn.coverReceipt = try await attachment.spokenPlayback
                .pauseCurrentSpokenMedia(interruptionID: turn.turnID)
            print(
                "[TuringLiveConversation] PR paused for active pre-PR dictation " +
                    "turnID=\(turn.turnID.uuidString) itemID=\(itemID) " +
                    "pauseResult=\(String(describing: turn.coverReceipt.result))"
            )
        } catch {
            print(
                "[TuringLiveConversation] PR pause failed during pre-PR dictation " +
                    "turnID=\(turn.turnID.uuidString) itemID=\(itemID) " +
                    "authoredPlaybackContinues=true " +
                    "error=\(error.localizedDescription)"
            )
        }
    }

    private func waitForAuthoredMediaCompletion(itemID: String) async -> Bool {
        if completedAuthoredMediaItemIDs.contains(itemID) {
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if completedAuthoredMediaItemIDs.contains(itemID) {
                    continuation.resume(returning: true)
                } else {
                    authoredMediaCompletionWaiters[itemID, default: [:]][waiterID] =
                        continuation
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelAuthoredMediaCompletionWaiter(
                    itemID: itemID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func markAuthoredMediaCompleted(itemID: String) {
        completedAuthoredMediaItemIDs.insert(itemID)
        let waiters = authoredMediaCompletionWaiters.removeValue(forKey: itemID)
            ?? [:]
        for continuation in waiters.values {
            continuation.resume(returning: true)
        }
    }

    private func cancelAuthoredMediaCompletionWaiter(
        itemID: String,
        waiterID: UUID
    ) {
        guard let continuation = authoredMediaCompletionWaiters[itemID]?
            .removeValue(forKey: waiterID) else {
            return
        }
        if authoredMediaCompletionWaiters[itemID]?.isEmpty == true {
            authoredMediaCompletionWaiters.removeValue(forKey: itemID)
        }
        continuation.resume(returning: false)
    }

    private func resumeAllAuthoredMediaCompletionWaiters(completed: Bool) {
        let waiters = authoredMediaCompletionWaiters.values.flatMap {
            Array($0.values)
        }
        authoredMediaCompletionWaiters.removeAll(keepingCapacity: false)
        for continuation in waiters {
            continuation.resume(returning: completed)
        }
    }

    private func preloadMicrophoneCTADuration(
        for item: TuringAuthoredMediaItem
    ) {
        guard authoredMediaDurationSeconds[item.id] == nil,
              microphoneCTADurationTasks[item.id] == nil else {
            return
        }
        let expectedGeneration = generation
        microphoneCTADurationTasks[item.id] = Task { [weak self] in
            let duration = await Self.readAudioDurationSeconds(
                fileURL: item.fileURL
            )
            guard Task.isCancelled == false, let self else { return }
            await self.microphoneCTADurationLoaded(
                duration,
                itemID: item.id,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func microphoneCTADurationLoaded(
        _ duration: Double?,
        itemID: String,
        expectedGeneration: UInt64
    ) async {
        microphoneCTADurationTasks.removeValue(forKey: itemID)
        guard expectedGeneration == generation,
              let duration,
              duration.isFinite,
              duration > 0 else {
            print(
                "[TuringLiveConversation] microphone CTA duration unavailable " +
                    "itemID=\(itemID)"
            )
            return
        }
        authoredMediaDurationSeconds[itemID] = duration
        guard microphoneCTAState?.itemID == itemID else { return }
        await configureMicrophoneCTA(
            itemID: itemID,
            durationSeconds: duration
        )
    }

    nonisolated private static func readAudioDurationSeconds(
        fileURL: URL
    ) async -> Double? {
        await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: fileURL),
                  file.fileFormat.sampleRate > 0 else {
                return nil
            }
            return Double(file.length) / file.fileFormat.sampleRate
        }.value
    }

    private func beginMicrophoneCTA(
        for item: TuringAuthoredMediaItem
    ) async {
        microphoneCTAGeneration &+= 1
        microphoneCTATimerTask?.cancel()
        microphoneCTATimerTask = nil
        let surfaces = Set(presentedSeedIDs.keys)
        microphoneCTAState = MicrophoneCTAPlaybackState(
            generation: microphoneCTAGeneration,
            itemID: item.id,
            surfaces: surfaces,
            prerecordingDurationSeconds: nil,
            transitionStepCount: 0,
            lastPublishedSaturationStep: nil,
            accumulatedPlaybackSeconds: 0,
            runningSince: ContinuousClock.now
        )
        desaturatedMicrophoneSurfaces.subtract(surfaces)
        if let duration = authoredMediaDurationSeconds[item.id] {
            await configureMicrophoneCTA(
                itemID: item.id,
                durationSeconds: duration
            )
        } else {
            preloadMicrophoneCTADuration(for: item)
        }
    }

    private func configureMicrophoneCTA(
        itemID: String,
        durationSeconds: Double
    ) async {
        guard var state = microphoneCTAState,
              state.itemID == itemID else {
            return
        }
        let stepCount = TuringPrerecordingMicrophoneCTAPolicy
            .transitionStepCount(
                prerecordingDurationSeconds: durationSeconds
            )
        let transitionDuration = TuringPrerecordingMicrophoneCTAPolicy
            .transitionDuration(
                prerecordingDurationSeconds: durationSeconds
            )
        state.prerecordingDurationSeconds = durationSeconds
        state.transitionStepCount = stepCount
        state.lastPublishedSaturationStep = nil
        microphoneCTAState = state
        print(
            "[TuringLiveConversation] microphone CTA scheduled " +
                "itemID=\(itemID) durationSeconds=\(durationSeconds) " +
                "transitionStartsAtFrame=1 " +
                "transitionDurationSeconds=\(transitionDuration) " +
                "fullyDesaturatedRemainingSeconds=" +
                "\(TuringPrerecordingMicrophoneCTAPolicy.fullyDesaturatedRemainingSeconds) " +
                "transitionSteps=\(stepCount)"
        )
        await refreshMicrophoneCTA(
            generation: state.generation,
            itemID: itemID,
            reason: stepCount == 0 ? "shortPR" : "prFrame1"
        )
    }

    private func pauseMicrophoneCTA(itemID: String) async {
        guard var state = microphoneCTAState,
              state.itemID == itemID,
              let runningSince = state.runningSince else {
            return
        }
        state.accumulatedPlaybackSeconds += Self.seconds(
            runningSince.duration(to: ContinuousClock.now)
        )
        state.runningSince = nil
        microphoneCTAState = state
        microphoneCTATimerTask?.cancel()
        microphoneCTATimerTask = nil
        await refreshMicrophoneCTA(
            generation: state.generation,
            itemID: itemID,
            reason: "prPaused"
        )
    }

    private func resumeMicrophoneCTA(itemID: String) async {
        guard var state = microphoneCTAState,
              state.itemID == itemID,
              state.runningSince == nil else {
            return
        }
        state.runningSince = ContinuousClock.now
        microphoneCTAState = state
        await refreshMicrophoneCTA(
            generation: state.generation,
            itemID: itemID,
            reason: "prResumed"
        )
    }

    private func scheduleMicrophoneCTATimer() {
        microphoneCTATimerTask?.cancel()
        microphoneCTATimerTask = nil
        guard let state = microphoneCTAState,
              let duration = state.prerecordingDurationSeconds,
              state.transitionStepCount > 0,
              let runningSince = state.runningSince else {
            return
        }
        let elapsed = state.accumulatedPlaybackSeconds + Self.seconds(
            runningSince.duration(to: ContinuousClock.now)
        )
        let transitionDuration = TuringPrerecordingMicrophoneCTAPolicy
            .transitionDuration(
                prerecordingDurationSeconds: duration
            )
        let completedSteps = min(
            state.transitionStepCount,
            Int(floor(
                min(1, max(0, elapsed / transitionDuration)) *
                    Double(state.transitionStepCount)
            ))
        )
        guard completedSteps < state.transitionStepCount else { return }
        let nextStepOffset =
            Double(completedSteps + 1) /
            Double(state.transitionStepCount) * transitionDuration
        let remaining = max(0, nextStepOffset - elapsed)
        let generation = state.generation
        let itemID = state.itemID
        microphoneCTATimerTask = Task { [weak self] in
            if remaining > 0 {
                let nanoseconds = UInt64(
                    min(remaining * 1_000_000_000, Double(UInt64.max))
                )
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard Task.isCancelled == false, let self else { return }
            await self.refreshMicrophoneCTA(
                generation: generation,
                itemID: itemID,
                reason: "linearDrainStep"
            )
        }
    }

    private func refreshMicrophoneCTA(
        generation expectedGeneration: UInt64,
        itemID: String,
        reason: String
    ) async {
        guard var state = microphoneCTAState,
              state.generation == expectedGeneration,
              state.itemID == itemID,
              let duration = state.prerecordingDurationSeconds else {
            return
        }
        microphoneCTATimerTask = nil
        let elapsed = state.accumulatedPlaybackSeconds + (
            state.runningSince.map {
                Self.seconds($0.duration(to: ContinuousClock.now))
            } ?? 0
        )
        let step = TuringPrerecordingMicrophoneCTAPolicy.saturationStep(
            prerecordingDurationSeconds: duration,
            elapsedPlaybackSeconds: elapsed,
            stepCount: state.transitionStepCount
        )
        if state.lastPublishedSaturationStep != step {
            state.lastPublishedSaturationStep = step
            microphoneCTAState = state
            let saturation = TuringPrerecordingMicrophoneCTAPolicy.saturation(
                prerecordingDurationSeconds: duration,
                elapsedPlaybackSeconds: elapsed,
                stepCount: state.transitionStepCount
            )
            if saturation == 0 {
                desaturatedMicrophoneSurfaces.formUnion(state.surfaces)
            } else {
                desaturatedMicrophoneSurfaces.subtract(state.surfaces)
            }
            await applyMicrophoneCTAEmphasis(
                StoryMicrophoneCTAEmphasis(saturation: saturation),
                surfaces: state.surfaces,
                reason: reason
            )
            print(
                "[TuringLiveConversation] microphone CTA drain " +
                    "itemID=\(itemID) elapsedSeconds=\(elapsed) " +
                    "saturation=\(saturation) step=\(step)/" +
                    "\(state.transitionStepCount)"
            )
        }
        scheduleMicrophoneCTATimer()
    }

    private func completeMicrophoneCTA(itemID: String) async {
        guard let state = microphoneCTAState,
              state.itemID == itemID else {
            return
        }
        microphoneCTATimerTask?.cancel()
        microphoneCTATimerTask = nil
        microphoneCTAState = nil
        desaturatedMicrophoneSurfaces.formUnion(state.surfaces)
        await applyMicrophoneCTAEmphasis(
            .desaturated,
            surfaces: state.surfaces,
            reason: "prCompleted"
        )
    }

    private func cancelMicrophoneCTA(reason: String) {
        microphoneCTAGeneration &+= 1
        microphoneCTATimerTask?.cancel()
        microphoneCTATimerTask = nil
        microphoneCTAState = nil
        for task in microphoneCTADurationTasks.values {
            task.cancel()
        }
        microphoneCTADurationTasks.removeAll(keepingCapacity: false)
        authoredMediaDurationSeconds.removeAll(keepingCapacity: false)
        desaturatedMicrophoneSurfaces.removeAll(keepingCapacity: false)
        print("[TuringLiveConversation] microphone CTA cancelled reason=\(reason)")
    }

    private func applyMicrophoneCTAEmphasis(
        _ emphasis: StoryMicrophoneCTAEmphasis,
        surfaces: Set<StoryInteractionSurfaceID>,
        reason: String
    ) async {
        guard let liveSession = session else { return }
        for surface in surfaces {
            do {
                try await arbiter.setLiveConversationMicrophoneCTAEmphasis(
                    emphasis,
                    surface: surface,
                    parentLease: liveSession.parentLease,
                    sessionID: liveSession.sessionID,
                    generation: liveSession.generation,
                    reason: "\(reason).\(surface.rawValue)"
                )
            } catch {
                print(
                    "[TuringLiveConversation] microphone CTA update ignored " +
                        "surface=\(surface.rawValue) reason=\(reason) " +
                        "error=\(error.localizedDescription)"
                )
            }
        }
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) +
            Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func beginTurn(
        surface: StoryInteractionSurfaceID,
        source: String,
        dictation: TuringDictationCoordinator
    ) async {
        guard case .ready = recoveryAvailability else {
            clearPendingHold(surface: surface)
            return
        }
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
            let selectedBeforeUpcomingPRStarted =
                actualAuthoredMediaStartedItemID != seed.authoredMediaItemID
            if selectedBeforeUpcomingPRStarted == false {
                liveSession = try await ensureProgressionHold(
                    liveSession,
                    reason: "microphoneSelected.\(surface.rawValue)"
                )
                session = liveSession
            } else {
                print(
                    "[TuringLiveConversation] pre-PR microphone selected " +
                        "itemID=\(seed.authoredMediaItemID) " +
                        "surface=\(surface.rawValue) selectable=true " +
                        "computeAhead=true progressionHold=false"
                )
            }
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
            print(
                "[TuringLiveConversation] dictation started " +
                    "turnID=\(turnID.uuidString) surface=\(surface.rawValue) " +
                    "computeAhead=\(selectedBeforeUpcomingPRStarted)"
            )
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
        if turn.coverReceipt.handle == nil,
           turn.coverReceipt.itemIdentity == "prerecordingPreFiller" {
            print(
                "[TuringLiveConversation] generated response held for " +
                    "upcoming PR completion turnID=\(turn.turnID.uuidString) " +
                    "itemID=\(turn.seed.authoredMediaItemID)"
            )
            return await waitForAuthoredMediaCompletion(
                itemID: turn.seed.authoredMediaItemID
            )
        }

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
            let restoredDesaturatedSurfaces =
                desaturatedMicrophoneSurfaces.intersection(
                    Set(snapshot.seedsBySurface.keys)
                )
            if restoredDesaturatedSurfaces.isEmpty == false {
                await applyMicrophoneCTAEmphasis(
                    .desaturated,
                    surfaces: restoredDesaturatedSurfaces,
                    reason: "retainedAvailability.\(reason)"
                )
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
        cancelMicrophoneCTA(reason: "attachmentReplaced")
        resumeAllAuthoredMediaCompletionWaiters(completed: false)
        completedAuthoredMediaItemIDs.removeAll(keepingCapacity: false)
        actualAuthoredMediaStartedItemID = nil
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
        try await TuringQwenNativeRecoveryCoordinator.shared.requireReady()
        guard let entry = item.liveConversationCatalogEntry else {
            return
        }
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
        let activation = try await TuringConversationMicrophoneActivationCoordinator
            .shared.authoredMediaStarted(
                entry: entry,
                item: item,
                descriptor: attachment.descriptor,
                parentSequenceID: attachment.parentSequenceID,
                identity: attachment.identity,
                expectedMicrophoneGeneration: attachment.microphoneGeneration,
                parentLease: liveSession.parentLease,
                liveSessionID: liveSession.sessionID,
                livePresentationGeneration: liveSession.generation,
                activationPhase: "actualPRStart"
            )
        currentAuthoredItemID = item.id
        currentAuthoredSeed = activation.seed
        presentedSeedIDs = activation.eligibleSeeds.seedsBySurface
            .mapValues(\.seedID)
        print(
            "[TuringLiveConversation] seed installed " +
                "itemID=\(item.id) seedID=\(activation.seed.seedID.uuidString) " +
                "phase=\(reason) microphoneContext=currentPromptVoice"
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
        guard case .ready = recoveryAvailability,
              var liveSession = session,
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

    private func ensureRecoveryAvailabilityObserver() {
        guard recoveryAvailabilityTask == nil else { return }
        recoveryAvailabilityTask = Task { [weak self] in
            let updates = await TuringQwenNativeRecoveryCoordinator.shared
                .availabilityUpdates()
            for await availability in updates {
                guard Task.isCancelled == false else { return }
                await self?.recoveryAvailabilityChanged(availability)
            }
        }
    }

    private func refreshRecoveryAvailabilityAndObserve() async {
        recoveryAvailability = await TuringQwenNativeRecoveryCoordinator.shared
            .currentAvailability()
        ensureRecoveryAvailabilityObserver()
    }

    private func recoveryAvailabilityChanged(
        _ availability: TuringQwenNativeRecoveryAvailability
    ) async {
        recoveryAvailability = availability
        switch availability {
        case .ready:
            if let activeResponseTurnID,
               let activeResponse = turns[activeResponseTurnID] {
                await exposeNextTurnMicrophonesIfPossible(for: activeResponse)
            }
        case .recovering, .unavailableUntilRelaunch:
            pendingHoldSurface = nil
            pendingHoldEndRequested = false
            cancelMicrophoneCTA(reason: "qwenRecoveryAvailability")
            presentedSeedIDs.removeAll(keepingCapacity: false)
            if let session {
                await arbiter.suspendLiveConversationMicrophones(
                    parentLease: session.parentLease,
                    sessionID: session.sessionID,
                    generation: session.generation,
                    unavailable: {
                        if case .unavailableUntilRelaunch = availability {
                            return true
                        }
                        return false
                    }(),
                    reason: "qwenRecoveryAvailability"
                )
            }
            print(
                "[TuringQwenRecovery] microphones suspended " +
                    "availability=\(String(describing: availability)) " +
                    "audiblePlaybackUnaffected=true"
            )
        }
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
