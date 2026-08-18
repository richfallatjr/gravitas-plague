import Foundation
import RealityKit

@MainActor
final class TuringStoryHamReceiverInteractionController:
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
        TuringStoryHamReceiverIconController
    private let tuningLoops:
        TuringRandomTuningLoopActor
    private let radioBed:
        any TuringHamReceiverBedControlling

    private weak var eventSink:
        (any TuringStoryWalkieInteractionEventSink)?

    private var ready = false
    private var holdActive = false
    private var playClaimPending = false
    private var activeConversationLease:
        StoryInteractionLease?
    private var activeRecordingRunID: UUID?
    private var activeResponseRunID: UUID?
    private var latestSnapshot =
        StoryInteractionSnapshot(
            revision: 0,
            turingGate: .closed,
            doorState: .closedUnloaded,
            exclusiveOwner: nil,
            capabilities: [],
            walkiePresentation: .hidden,
            doorPresentation: .hidden,
            dadFramePresentation: .hidden,
            hamReceiverPresentation: .hidden
        )

    private var playTask: Task<Void, Never>?
    private var dictationStartTask:
        Task<Void, Never>?
    private var conversationTask:
        Task<Void, Never>?

    convenience init() {
        self.init(
            gate:
                TuringFlowInteractionGateController
                    .shared,
            episodeFlow:
                TuringEpisodeFlowController
                    .shared,
            dictation: nil,
            iconController: nil,
            tuningLoops:
                TuringRandomTuningLoopActor
                    .hamReceiver,
            radioBed:
                TuringHamReceiverBedActor.shared
        )
    }

    init(
        gate:
            TuringFlowInteractionGateController,
        episodeFlow:
            TuringEpisodeFlowController,
        dictation:
            TuringDictationCoordinator?,
        iconController:
            TuringStoryHamReceiverIconController?,
        tuningLoops:
            TuringRandomTuningLoopActor,
        radioBed:
            any TuringHamReceiverBedControlling
    ) {
        self.gate = gate
        self.episodeFlow = episodeFlow
        self.dictation =
            dictation ??
            TuringDictationCoordinator()
        self.iconController =
            iconController ??
            TuringStoryHamReceiverIconController()
        self.tuningLoops = tuningLoops
        self.radioBed = radioBed
        self.dictation.onEvent = {
            [weak self]
            event in
            self?.eventSink?
                .publishTuringDictationEvent(
                    event
                )
        }
    }

    func setEventSink(
        _ sink:
            (any
                TuringStoryWalkieInteractionEventSink)?
    ) {
        eventSink = sink
    }

    func hamReceiverInstalled(
        iconAnchor: Entity,
        hamReceiverRoot: Entity,
        resourcesReady: Bool
    ) {
        iconController.install(
            iconAnchor: iconAnchor,
            hamReceiverRoot: hamReceiverRoot
        )
        ready = resourcesReady
        guard resourcesReady else {
            gate.close(
                surfaceID: .hamReceiver,
                reason:
                    "hamReceiverResourcesIncomplete"
            )
            applyInteractionSnapshot(
                latestSnapshot
            )
            return
        }
        applyInteractionSnapshot(
            latestSnapshot
        )
    }

    func bind(
        _ binding: TuringStorySurfaceFlowBinding,
        initialState: TuringFlowInteractionGateController.State,
        reason: String
    ) {
        precondition(binding.interactionSurface == .hamReceiver)
        self.binding = binding
        gate.applyStableState(
            initialState,
            surfaceID: .hamReceiver,
            reason: reason
        )
    }

    func stageBinding(
        _ binding: TuringStorySurfaceFlowBinding,
        reason: String
    ) {
        precondition(binding.interactionSurface == .hamReceiver)
        self.binding = binding
        print("[TuringHamReceiver] binding staged root=\(binding.rootScriptPointID) reason=\(reason)")
    }

    func hamReceiverRemoved(reason: String) {
        let staleLease =
            activeConversationLease
        let staleRunID =
            activeRecordingRunID
        let staleResponseRunID =
            activeResponseRunID
        let staleConversationKey = binding?.conversationKey
        ready = false
        binding = nil
        holdActive = false
        playClaimPending = false
        playTask?.cancel()
        dictationStartTask?.cancel()
        conversationTask?.cancel()
        playTask = nil
        dictationStartTask = nil
        conversationTask = nil
        activeConversationLease = nil
        activeRecordingRunID = nil
        activeResponseRunID = nil
        iconController.remove()
        gate.close(
            surfaceID: .hamReceiver,
            reason:
                "hamReceiverRemoved.\(reason)"
        )
        Task {
            await self.episodeFlow.cancelActiveSequence(
                reason:
                    "hamReceiverRemoved.\(reason)"
            )
            await self.dictation.cancel(
                reason:
                    "hamReceiverRemoved.\(reason)"
            )
            if let staleRunID {
                await self.tuningLoops.endGap(
                    ownerID:
                        staleRunID.uuidString,
                    reason:
                        "hamReceiverRemoved.\(reason)"
                )
                await self.radioBed.endSession(
                    ownerID:
                        staleRunID.uuidString,
                    reason:
                        "hamReceiverRemoved.\(reason)"
                )
            }
            if let staleResponseRunID {
                await self.tuningLoops.endGap(
                    ownerID:
                        staleResponseRunID
                            .uuidString,
                    reason:
                        "hamReceiverRemoved.\(reason)"
                )
                await self.radioBed.endSession(
                    ownerID:
                        staleResponseRunID
                            .uuidString,
                    reason:
                        "hamReceiverRemoved.\(reason)"
                )
            }
            if let staleLease {
                await StoryInteractionArbiter
                    .shared
                    .release(
                        staleLease,
                        reason:
                            "hamReceiverRemoved.\(reason)"
                    )
            }
            if let staleConversationKey {
                await TuringConversationInputStore.shared.clear(
                    key: staleConversationKey
                )
            }
        }
        print(
            "[TuringHamReceiver] removed reason=\(reason)"
        )
    }

    func playTapped(source: String) {
        guard ready,
              let binding,
              playClaimPending == false,
              latestSnapshot.capabilities
                .contains(.hamReceiverPlay) else {
            return
        }

        playClaimPending = true
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.playClaimPending = false
            }
            let result =
                await self.episodeFlow.start(
                    scriptPointID:
                        binding.rootScriptPointID,
                    trigger: .userPlay
                )
            if result.succeeded == false,
               self.ready {
                self.gate.armPlay(
                    surfaceID: .hamReceiver,
                    reason:
                        "hamReceiverFlowFailed.\(source)"
                )
                self.eventSink?
                    .publishTuringDictationEvent(
                        .responseFailed(
                            result.pickerStatus
                        )
                    )
            }
        }
    }

    func microphoneHoldBegan(
        source: String
    ) {
        if TuringStoryLiveMicrophoneActionRouter.shared.microphoneHoldBegan(
            surface: .hamReceiver,
            source: source,
            dictation: dictation,
            eventSink: eventSink
        ) {
            return
        }
        guard ready,
              holdActive == false,
              latestSnapshot.capabilities
                .contains(
                    .hamReceiverMicrophone
                ) else {
            return
        }

        holdActive = true
        dictationStartTask?.cancel()
        dictationStartTask =
            Task { [weak self] in
                guard let self else {
                    return
                }

                let runID = UUID()
                let lease:
                    StoryInteractionLease
                do {
                    lease =
                        try await
                        TuringHighMemoryPreflightCoordinator
                            .shared
                            .acquireInteractionLease(
                                runID:
                                    "conversation.\(runID.uuidString)",
                                source:
                                    "hamReceiverMicrophone.\(source)",
                                mode: .manual,
                                interactionSurface:
                                    .hamReceiver
                            )
                } catch {
                    self.holdActive = false
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .failed(
                                "Device operation failed: \(error.localizedDescription)"
                            )
                        )
                    return
                }

                guard self.holdActive,
                      Task.isCancelled ==
                        false else {
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "hamReceiverHoldEndedBeforeLeaseUse"
                        )
                    return
                }

                do {
                    try await self.radioBed
                        .beginSession(
                            ownerID:
                                runID.uuidString
                        )
                } catch {
                    self.holdActive = false
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "hamReceiverAmbientStaticFailed"
                        )
                    self.gate
                        .ensureMicrophoneAvailable(
                            surfaceID:
                                .hamReceiver,
                            reason:
                                "hamReceiverAmbientStaticFailed"
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
                      Task.isCancelled ==
                        false else {
                    await self.radioBed.endSession(
                        ownerID:
                            runID.uuidString,
                        reason:
                            "hamReceiverHoldEndedBeforeStaticUse"
                    )
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "hamReceiverHoldEndedBeforeStaticUse"
                        )
                    return
                }

                self.activeConversationLease =
                    lease
                self.activeRecordingRunID =
                    runID
                self.gate.beginConversation(
                    conversationRunID:
                        runID,
                    surfaceID: .hamReceiver
                )
                await self.tuningLoops.beginGap(
                    ownerID: runID.uuidString,
                    waitingForSegmentIndex: 0,
                    reason:
                        "conversationDictationBegan"
                )
                print("""
                [TuringHamReceiverConversation] dictation audio beds started
                  conversationRunID: \(runID.uuidString)
                  ambientStaticGainDB: \(TuringRollingBenchTuning.ambientStaticGainDB)
                  ambientStaticContinuesUnderTuningAndSpeech: true
                """)
                await self.dictation
                    .beginHoldToRecord()
            }
    }

    func microphoneHoldEnded(
        source: String
    ) {
        if TuringStoryLiveMicrophoneActionRouter.shared.microphoneHoldEnded(
            surface: .hamReceiver,
            source: source
        ) {
            return
        }
        guard holdActive else {
            return
        }
        holdActive = false

        guard dictation.isRecording else {
            let startupTask =
                dictationStartTask
            startupTask?.cancel()
            dictationStartTask = nil
            let lease =
                activeConversationLease
            let runID =
                activeRecordingRunID
            activeConversationLease = nil
            activeRecordingRunID = nil
            Task {
                await startupTask?.value
                if let runID {
                    await tuningLoops.endGap(
                        ownerID: runID.uuidString,
                        reason:
                            "hamReceiverHoldEndedBeforeRecording"
                    )
                    await radioBed.endSession(
                        ownerID:
                            runID.uuidString,
                        reason:
                            "hamReceiverHoldEndedBeforeRecording"
                    )
                }
                if let lease {
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "hamReceiverHoldEndedBeforeRecording"
                        )
                }
                if let runID {
                    gate.restoreMicrophoneAfterConversation(
                        conversationRunID:
                            runID,
                        surfaceID:
                            .hamReceiver
                    )
                }
            }
            return
        }

        guard let lease =
                activeConversationLease else {
            gate.ensureMicrophoneAvailable(
                surfaceID: .hamReceiver,
                reason:
                    "hamReceiverConversationLeaseMissing"
            )
            return
        }

        let conversationRunID =
            activeRecordingRunID ?? UUID()
        activeConversationLease = nil
        activeRecordingRunID = nil
        activeResponseRunID =
            conversationRunID

        conversationTask?.cancel()
        conversationTask =
            Task { [weak self] in
                guard let self else {
                    return
                }
                do {
                    guard let binding = self.binding else {
                        throw TuringRuntimeError.invalidConfig("Ham-receiver conversation binding is unavailable.")
                    }
                    let transcript =
                        try await self.dictation
                            .endHoldToSend()
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .processingStarted(
                                finalTranscript:
                                    transcript
                            )
                        )
                    print("""
                    [TuringHamReceiver] conversation submitted
                      characterID: \(binding.conversationCharacterID)
                      outputRoute: \(binding.conversationOutputRoute.rawValue)
                      conversationKey: \(binding.conversationKey)
                      userInputUTF16: \(transcript.utf16.count)
                      dialogueHistoryIncluded: false
                    """)

                    let result =
                        await TuringFlowConversationRunner
                            .run(
                                request:
                                    TuringFlowConversationRequest(
                                        conversationRunID:
                                            conversationRunID,
                                        characterID:
                                            binding.conversationCharacterID,
                                        outputRoute:
                                            binding.conversationOutputRoute,
                                        conversationKey:
                                            binding.conversationKey,
                                        playerDictation:
                                            transcript,
                                        interactionLease:
                                            lease,
                                        interactionSurface:
                                            binding.interactionSurface
                                    ),
                                inputStore:
                                    .shared,
                                onSegmentZeroReady: {
                                    [weak self]
                                    in
                                    self?
                                        .eventSink?
                                        .publishTuringDictationEvent(
                                            .responseSegmentZeroReady(
                                                clearAfterSeconds:
                                                    2
                                            )
                                        )
                                }
                            )
                    await self.tuningLoops.endGap(
                        ownerID:
                            conversationRunID.uuidString,
                        reason:
                            "hamReceiverConversationFinished.\(result.succeeded)"
                    )
                    await self.radioBed.endSession(
                        ownerID:
                            conversationRunID.uuidString,
                        reason:
                            "hamReceiverConversationFinished.\(result.succeeded)"
                    )
                    self.activeResponseRunID = nil
                    self.eventSink?
                        .publishTuringDictationEvent(
                            result.succeeded
                                ? .responseAudioFinished
                                : .responseFailed(
                                    result.pickerStatus
                                )
                        )
                } catch {
                    await self.tuningLoops.endGap(
                        ownerID:
                            conversationRunID.uuidString,
                        reason:
                            "hamReceiverConversationFailedBeforePlayback"
                    )
                    await self.radioBed.endSession(
                        ownerID:
                            conversationRunID.uuidString,
                        reason:
                            "hamReceiverConversationFailedBeforePlayback"
                    )
                    self.activeResponseRunID = nil
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "hamReceiverDictationFailedBeforeConversation"
                        )
                    self.gate
                        .restoreMicrophoneAfterConversation(
                            conversationRunID:
                                conversationRunID,
                            surfaceID:
                                .hamReceiver
                        )
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .failed(
                                error.localizedDescription
                            )
                        )
                }
            }
    }

    func applyInteractionSnapshot(
        _ snapshot:
            StoryInteractionSnapshot
    ) {
        latestSnapshot = snapshot
        iconController.apply(
            ready
                ? snapshot
                    .hamReceiverPresentation
                : .hidden,
            activity: ready
                ? snapshot.turingSurfacePresentations[.hamReceiver]?.activity
                    ?? .hidden
                : .hidden
        )
    }

    func shutdown(reason: String) async {
        let staleLease =
            activeConversationLease
        hamReceiverRemoved(reason: reason)
        await dictation.cancel(reason: reason)
        if let staleLease {
            await StoryInteractionArbiter
                .shared
                .release(
                    staleLease,
                    reason:
                        "hamReceiverShutdown.\(reason)"
                )
        }
    }
}
