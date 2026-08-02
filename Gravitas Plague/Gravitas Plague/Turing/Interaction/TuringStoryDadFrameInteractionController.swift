import Foundation
import RealityKit

@MainActor
final class TuringStoryDadFrameInteractionController:
    StoryInteractionSurfacePresenting
{
    private var binding: TuringStorySurfaceFlowBinding?
    private let gate:
        TuringFlowInteractionGateController
    private let episodeFlow:
        TuringEpisodeFlowController
    private let dictation:
        TuringDictationCoordinator
    private let iconController:
        TuringStoryDadFrameIconController

    private weak var eventSink:
        (any TuringStoryWalkieInteractionEventSink)?

    private var ready = false
    private var holdActive = false
    private var playClaimPending = false
    private var activeConversationLease:
        StoryInteractionLease?
    private var activeRecordingRunID: UUID?
    private var activeConversationMusicIdentity:
        TuringFlowIdentity?
    private var latestSnapshot = StoryInteractionSnapshot(
        revision: 0,
        turingGate: .closed,
        doorState: .closedUnloaded,
        exclusiveOwner: nil,
        capabilities: [],
        walkiePresentation: .hidden,
        doorPresentation: .hidden,
        dadFramePresentation: .hidden
    )

    private var playTask: Task<Void, Never>?
    private var dictationStartTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?

    init(
        gate: TuringFlowInteractionGateController = .shared,
        episodeFlow: TuringEpisodeFlowController = .shared,
        dictation: TuringDictationCoordinator? = nil,
        iconController: TuringStoryDadFrameIconController? = nil
    ) {
        self.gate = gate
        self.episodeFlow = episodeFlow
        self.dictation = dictation ?? TuringDictationCoordinator()
        self.iconController =
            iconController ?? TuringStoryDadFrameIconController()
        self.dictation.onEvent = { [weak self] event in
            self?.eventSink?.publishTuringDictationEvent(event)
        }
    }

    func setEventSink(
        _ sink: (any TuringStoryWalkieInteractionEventSink)?
    ) {
        eventSink = sink
    }

    func dadFrameInstalled(
        iconAnchor: Entity,
        dadFrameRoot: Entity
    ) {
        iconController.install(
            iconAnchor: iconAnchor,
            dadFrameRoot: dadFrameRoot
        )
        ready = true
        applyInteractionSnapshot(latestSnapshot)
    }

    func bind(
        _ binding: TuringStorySurfaceFlowBinding,
        initialState: TuringFlowInteractionGateController.State,
        reason: String
    ) {
        precondition(binding.interactionSurface == .dadFrame)
        self.binding = binding
        gate.applyStableState(
            initialState,
            surfaceID: .dadFrame,
            reason: reason
        )
    }

    func stageBinding(
        _ binding: TuringStorySurfaceFlowBinding,
        reason: String
    ) {
        precondition(binding.interactionSurface == .dadFrame)
        self.binding = binding
        print("[TuringDadFrame] binding staged root=\(binding.rootScriptPointID) reason=\(reason)")
    }

    func dadFrameRemoved(reason: String) {
        let startupTask = dictationStartTask
        let musicIdentity = activeConversationMusicIdentity
        ready = false
        let staleConversationKey = binding?.conversationKey
        binding = nil
        holdActive = false
        playClaimPending = false
        playTask?.cancel()
        startupTask?.cancel()
        conversationTask?.cancel()
        playTask = nil
        dictationStartTask = nil
        conversationTask = nil
        activeConversationMusicIdentity = nil
        iconController.remove()
        if let musicIdentity {
            Task {
                await startupTask?.value
                await TuringFlowMediaCueCoordinator.shared
                    .stopIfNeeded(
                        identity: musicIdentity,
                        reason:
                            "dadFrameRemoved.\(reason)"
                    )
            }
        }
        if let staleConversationKey {
            Task {
                await TuringConversationInputStore.shared.clear(
                    key: staleConversationKey
                )
            }
        }
        print("[TuringDadFrame] removed reason=\(reason)")
    }

    func playTapped(source: String) {
        guard ready,
              let binding,
              playClaimPending == false,
              latestSnapshot.capabilities
                .contains(.dadFramePlay) else {
            return
        }

        playClaimPending = true
        print("""
        [TuringDadPhoto] play claimed
          scriptPointID: \(binding.rootScriptPointID)
          interactionSurface: \(StoryInteractionSurfaceID.dadFrame.rawValue)
          conversationKey: \(binding.conversationKey)
          source: \(source)
        """)
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.playClaimPending = false
            }
            let result = await self.episodeFlow.start(
                scriptPointID: binding.rootScriptPointID,
                trigger: .userPlay
            )
            if result.succeeded == false,
               self.ready {
                self.gate.armPlay(
                    surfaceID: .dadFrame,
                    reason: "dadMemoryFailed.\(source)"
                )
                self.eventSink?.publishTuringDictationEvent(
                    .responseFailed(result.pickerStatus)
                )
            }
        }
    }

    func microphoneHoldBegan(source: String) {
        guard ready,
              holdActive == false,
              latestSnapshot.capabilities
                .contains(.dadFrameMicrophone) else {
            return
        }

        holdActive = true
        dictationStartTask?.cancel()
        dictationStartTask = Task { [weak self] in
            guard let self else {
                return
            }

            let runID = UUID()
            let musicIdentity =
                self.conversationMusicIdentity(
                    runID: runID
                )
            self.activeConversationMusicIdentity =
                musicIdentity
            do {
                guard let binding = self.binding else {
                    throw TuringRuntimeError.invalidConfig("Dad-frame flow binding is unavailable.")
                }
                let descriptor =
                    try TuringFlowDescriptorStore()
                        .require(binding.rootScriptPointID)
                try await TuringFlowMediaCueCoordinator
                    .shared
                    .startIfNeeded(
                        descriptor: descriptor,
                        identity: musicIdentity
                    )
                print("""
                [TuringDadPhotoMusic] conversation score started
                  boundary: recordingPinchBegan
                  conversationRunID: \(runID.uuidString)
                """)
            } catch {
                self.holdActive = false
                await self.stopConversationMusic(
                    identity: musicIdentity,
                    reason:
                        "conversationMusicStartFailed"
                )
                self.eventSink?
                    .publishTuringDictationEvent(
                        .failed(
                            "Device operation failed: \(error.localizedDescription)"
                        )
                    )
                return
            }

            guard self.holdActive,
                  Task.isCancelled == false else {
                await self.stopConversationMusic(
                    identity: musicIdentity,
                    reason:
                        "dadFrameHoldEndedBeforePreflight"
                )
                return
            }

            let lease: StoryInteractionLease
            do {
                lease = try await
                    TuringHighMemoryPreflightCoordinator.shared
                        .acquireInteractionLease(
                            runID:
                                "conversation.\(runID.uuidString)",
                            source:
                                "dadFrameMicrophone.\(source)",
                            mode: .manual,
                            interactionSurface: .dadFrame
                        )
            } catch {
                self.holdActive = false
                await self.stopConversationMusic(
                    identity: musicIdentity,
                    reason:
                        "dadFrameConversationPreflightFailed"
                )
                self.eventSink?.publishTuringDictationEvent(
                    .failed(
                        "Device operation failed: \(error.localizedDescription)"
                    )
                )
                return
            }

            guard self.holdActive,
                  Task.isCancelled == false else {
                await StoryInteractionArbiter.shared.release(
                    lease,
                    reason: "dadFrameHoldEndedBeforeLeaseUse"
                )
                await self.stopConversationMusic(
                    identity: musicIdentity,
                    reason:
                        "dadFrameHoldEndedBeforeLeaseUse"
                )
                return
            }

            self.activeConversationLease = lease
            self.activeRecordingRunID = runID
            self.gate.beginConversation(
                conversationRunID: runID,
                surfaceID: .dadFrame
            )
            await self.dictation.beginHoldToRecord()
        }
    }

    func microphoneHoldEnded(source: String) {
        guard holdActive else {
            return
        }
        holdActive = false

        guard dictation.isRecording else {
            let startupTask = dictationStartTask
            startupTask?.cancel()
            dictationStartTask = nil
            let lease = activeConversationLease
            let runID = activeRecordingRunID
            let musicIdentity =
                activeConversationMusicIdentity
            activeConversationLease = nil
            activeRecordingRunID = nil
            Task {
                await startupTask?.value
                if let lease {
                    await StoryInteractionArbiter.shared.release(
                        lease,
                        reason:
                            "dadFrameHoldEndedBeforeRecording"
                    )
                }
                if let runID {
                    gate.restoreMicrophoneAfterConversation(
                        conversationRunID: runID,
                        surfaceID: .dadFrame
                    )
                }
                if let musicIdentity {
                    await self.stopConversationMusic(
                        identity:
                            musicIdentity,
                        reason:
                            "dadFrameHoldEndedBeforeRecording"
                    )
                }
            }
            return
        }

        guard let lease = activeConversationLease else {
            gate.ensureMicrophoneAvailable(
                surfaceID: .dadFrame,
                reason: "dadFrameConversationLeaseMissing"
            )
            if let musicIdentity =
                    activeConversationMusicIdentity {
                Task {
                    await self.stopConversationMusic(
                        identity:
                            musicIdentity,
                        reason:
                            "dadFrameConversationLeaseMissing"
                    )
                }
            }
            return
        }
        let conversationRunID =
            activeRecordingRunID ?? UUID()
        let musicIdentity =
            activeConversationMusicIdentity
        activeConversationLease = nil
        activeRecordingRunID = nil

        conversationTask?.cancel()
        conversationTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                guard let binding = self.binding else {
                    throw TuringRuntimeError.invalidConfig("Dad-frame conversation binding is unavailable.")
                }
                let transcript =
                    try await self.dictation.endHoldToSend()
                self.eventSink?.publishTuringDictationEvent(
                    .processingStarted(
                        finalTranscript: transcript
                    )
                )
                print("""
                [TuringDadPhoto] conversation submitted
                  characterID: \(binding.conversationCharacterID)
                  outputRoute: \(binding.conversationOutputRoute.rawValue)
                  conversationKey: \(binding.conversationKey)
                  userInputUTF16: \(transcript.utf16.count)
                  dialogueHistoryIncluded: false
                """)

                let result =
                    await TuringFlowConversationRunner.run(
                        request:
                            TuringFlowConversationRequest(
                                characterID: binding.conversationCharacterID,
                                outputRoute: binding.conversationOutputRoute,
                                conversationKey:
                                    binding.conversationKey,
                                playerDictation: transcript,
                                interactionLease: lease,
                                interactionSurface:
                                    binding.interactionSurface
                            ),
                        inputStore: .shared,
                        onSegmentZeroReady: { [weak self] in
                            self?.eventSink?
                                .publishTuringDictationEvent(
                                    .responseSegmentZeroReady(
                                        clearAfterSeconds: 2
                                    )
                                )
                        }
                    )
                if let musicIdentity {
                    await self.stopConversationMusic(
                        identity:
                            musicIdentity,
                        reason:
                            result.succeeded
                                ? "conversationTTSPlaybackCompleted"
                                : "conversationVoiceFailed"
                    )
                }
                self.eventSink?.publishTuringDictationEvent(
                    result.succeeded
                        ? .responseAudioFinished
                        : .responseFailed(result.pickerStatus)
                )
            } catch {
                await StoryInteractionArbiter.shared.release(
                    lease,
                    reason:
                        "dadFrameDictationFailedBeforeConversation"
                )
                self.gate.restoreMicrophoneAfterConversation(
                    conversationRunID: conversationRunID,
                    surfaceID: .dadFrame
                )
                if let musicIdentity {
                    await self.stopConversationMusic(
                        identity:
                            musicIdentity,
                        reason:
                            "dadFrameDictationFailedBeforeConversation"
                    )
                }
                self.eventSink?.publishTuringDictationEvent(
                    .failed(error.localizedDescription)
                )
            }
        }
    }

    func applyInteractionSnapshot(
        _ snapshot: StoryInteractionSnapshot
    ) {
        latestSnapshot = snapshot
        iconController.apply(
            ready
                ? snapshot.dadFramePresentation
                : .hidden
        )
    }

    func shutdown(reason: String) async {
        let staleLease = activeConversationLease
        dadFrameRemoved(reason: reason)
        activeConversationLease = nil
        activeRecordingRunID = nil
        await dictation.cancel(reason: reason)
        if let staleLease {
            await StoryInteractionArbiter.shared.release(
                staleLease,
                reason: "dadFrameShutdown.\(reason)"
            )
        }
    }

    private func conversationMusicIdentity(
        runID: UUID
    ) -> TuringFlowIdentity {
        let activeBinding = binding ?? .prologueDadPhoto
        return TuringFlowIdentity(
            flowInstanceID: runID,
            scriptPointID:
                "conversation.\(runID.uuidString)",
            characterID: activeBinding.conversationCharacterID,
            prerecordingID: "none",
            voicePromptID: "conversationPrompt",
            interactionSurface: activeBinding.interactionSurface
        )
    }

    private func stopConversationMusic(
        identity: TuringFlowIdentity,
        reason: String
    ) async {
        if activeConversationMusicIdentity == identity {
            activeConversationMusicIdentity = nil
        }
        await TuringFlowMediaCueCoordinator.shared
            .stopIfNeeded(
                identity: identity,
                reason: reason
            )
    }
}
