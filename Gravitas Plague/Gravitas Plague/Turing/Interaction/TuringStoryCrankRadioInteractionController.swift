import Foundation
import RealityKit

@MainActor
final class TuringStoryCrankRadioInteractionController:
    StoryInteractionSurfacePresenting
{
    private var binding: TuringStorySurfaceFlowBinding? =
        .prologueCrankRadio
    private let gate:
        TuringFlowInteractionGateController
    private let episodeFlow:
        TuringEpisodeFlowController
    private let dictation:
        TuringDictationCoordinator
    private let iconController:
        TuringStoryCrankRadioIconController
    private let tuningLoops:
        TuringCrankRadioTuningLoopActor
    private let radioBed:
        any TuringRollingBenchRadioBedControlling

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
            crankRadioPresentation: .hidden
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
                TuringCrankRadioTuningLoopActor.shared,
            radioBed:
                TuringRollingBenchRadioBedActor.shared
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
            TuringStoryCrankRadioIconController?,
        tuningLoops:
            TuringCrankRadioTuningLoopActor,
        radioBed:
            any TuringRollingBenchRadioBedControlling
    ) {
        self.gate = gate
        self.episodeFlow = episodeFlow
        self.dictation =
            dictation ??
            TuringDictationCoordinator()
        self.iconController =
            iconController ??
            TuringStoryCrankRadioIconController()
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

    func crankRadioInstalled(
        iconAnchor: Entity,
        crankRadioRoot: Entity
    ) {
        iconController.install(
            iconAnchor: iconAnchor,
            crankRadioRoot: crankRadioRoot
        )
        ready = true
        gate.close(
            surfaceID: .crankRadio,
            reason: "crankRadioInstalledClosed"
        )
        applyInteractionSnapshot(
            latestSnapshot
        )
    }

    func bind(
        _ binding: TuringStorySurfaceFlowBinding,
        initialState: TuringFlowInteractionGateController.State,
        reason: String
    ) {
        precondition(binding.interactionSurface == .crankRadio)
        self.binding = binding
        gate.applyStableState(
            initialState,
            surfaceID: .crankRadio,
            reason: reason
        )
    }

    func stageBinding(
        _ binding: TuringStorySurfaceFlowBinding,
        reason: String
    ) {
        precondition(binding.interactionSurface == .crankRadio)
        self.binding = binding
        print(
            "[TuringCrankRadio] binding staged root=\(binding.rootScriptPointID) reason=\(reason)"
        )
    }

    func crankRadioRemoved(reason: String) {
        let staleLease =
            activeConversationLease
        let staleConversationKey = binding?.conversationKey
        let staleRunID =
            activeRecordingRunID
        let staleResponseRunID =
            activeResponseRunID
        ready = false
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
            surfaceID: .crankRadio,
            reason:
                "crankRadioRemoved.\(reason)"
        )
        Task {
            await self.dictation.cancel(
                reason:
                    "crankRadioRemoved.\(reason)"
            )
            if let staleRunID {
                await self.tuningLoops.endGap(
                    ownerID:
                        staleRunID.uuidString,
                    reason:
                        "crankRadioRemoved.\(reason)"
                )
                await self.radioBed.endSession(
                    ownerID:
                        staleRunID.uuidString,
                    reason:
                        "crankRadioRemoved.\(reason)"
                )
            }
            if let staleResponseRunID {
                await self.tuningLoops.endGap(
                    ownerID:
                        staleResponseRunID
                            .uuidString,
                    reason:
                        "crankRadioRemoved.\(reason)"
                )
                await self.radioBed.endSession(
                    ownerID:
                        staleResponseRunID
                            .uuidString,
                    reason:
                        "crankRadioRemoved.\(reason)"
                )
            }
            if let staleLease {
                await StoryInteractionArbiter
                    .shared
                    .release(
                        staleLease,
                        reason:
                            "crankRadioRemoved.\(reason)"
                    )
            }
            if let staleConversationKey {
                await TuringConversationInputStore
                    .shared
                    .clear(key: staleConversationKey)
            }
        }
        print(
            "[TuringCrankRadio] removed reason=\(reason)"
        )
    }

    func playTapped(source: String) {
        guard ready,
              playClaimPending == false,
              latestSnapshot.capabilities
                .contains(.crankRadioPlay) else {
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
            guard let binding = self.binding else {
                self.gate.close(
                    surfaceID: .crankRadio,
                    reason: "crankRadioBindingMissing"
                )
                return
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
                    surfaceID: .crankRadio,
                    reason:
                        "crankRadioFlowFailed.\(source)"
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
            surface: .crankRadio,
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
                    .crankRadioMicrophone
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
                                    "crankRadioMicrophone.\(source)",
                                mode: .manual,
                                interactionSurface:
                                    .crankRadio
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
                                "crankRadioHoldEndedBeforeLeaseUse"
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
                                "crankRadioAmbientStaticFailed"
                        )
                    self.gate
                        .ensureMicrophoneAvailable(
                            surfaceID:
                                .crankRadio,
                            reason:
                                "crankRadioAmbientStaticFailed"
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
                            "crankRadioHoldEndedBeforeStaticUse"
                    )
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "crankRadioHoldEndedBeforeStaticUse"
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
                    surfaceID: .crankRadio
                )
                await self.tuningLoops.beginGap(
                    ownerID: runID.uuidString,
                    waitingForSegmentIndex: 0,
                    reason:
                        "conversationDictationBegan"
                )
                print("""
                [TuringCrankRadioConversation] dictation audio beds started
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
            surface: .crankRadio,
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
                            "crankRadioHoldEndedBeforeRecording"
                    )
                    await radioBed.endSession(
                        ownerID:
                            runID.uuidString,
                        reason:
                            "crankRadioHoldEndedBeforeRecording"
                    )
                }
                if let lease {
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "crankRadioHoldEndedBeforeRecording"
                        )
                }
                if let runID {
                    gate.restoreMicrophoneAfterConversation(
                        conversationRunID:
                            runID,
                        surfaceID:
                            .crankRadio
                    )
                }
            }
            return
        }

        guard let lease =
                activeConversationLease else {
            gate.ensureMicrophoneAvailable(
                surfaceID: .crankRadio,
                reason:
                    "crankRadioConversationLeaseMissing"
            )
            return
        }

        guard let binding else {
            holdActive = false
            activeConversationLease = nil
            activeRecordingRunID = nil
            Task {
                await StoryInteractionArbiter.shared.release(
                    lease,
                    reason: "crankRadioConversationBindingMissing"
                )
            }
            gate.close(
                surfaceID: .crankRadio,
                reason: "crankRadioConversationBindingMissing"
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
                    let transcript =
                        try await self.dictation
                            .endHoldToSend()
                    let seed = try await StoryInteractionArbiter.shared
                        .currentLatchedConversationSeed(surface: .crankRadio)
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .processingStarted(
                                finalTranscript:
                                    transcript
                            )
                        )
                    print("""
                    [TuringCrankRadio] conversation submitted
                      characterID: \(seed.characterID)
                      outputRoute: \(seed.outputRoute.rawValue)
                      conversationKey: \(seed.conversationKey)
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
                                            seed.characterID,
                                        outputRoute:
                                            seed.outputRoute,
                                        conversationKey:
                                            seed.conversationKey,
                                        playerDictation:
                                            transcript,
                                        interactionLease:
                                            lease,
                                        interactionSurface:
                                            .crankRadio,
                                        immutableSeed:
                                            seed
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
                            "crankRadioConversationFinished.\(result.succeeded)"
                    )
                    await self.radioBed.endSession(
                        ownerID:
                            conversationRunID.uuidString,
                        reason:
                            "crankRadioConversationFinished.\(result.succeeded)"
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
                            "crankRadioConversationFailedBeforePlayback"
                    )
                    await self.radioBed.endSession(
                        ownerID:
                            conversationRunID.uuidString,
                        reason:
                            "crankRadioConversationFailedBeforePlayback"
                    )
                    self.activeResponseRunID = nil
                    await StoryInteractionArbiter
                        .shared
                        .release(
                            lease,
                            reason:
                                "crankRadioDictationFailedBeforeConversation"
                        )
                    self.gate
                        .restoreMicrophoneAfterConversation(
                            conversationRunID:
                                conversationRunID,
                            surfaceID:
                                .crankRadio
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
                    .crankRadioPresentation
                : .hidden,
            activity: ready
                ? snapshot.turingSurfacePresentations[.crankRadio]?.activity
                    ?? .hidden
                : .hidden
        )
    }

    func shutdown(reason: String) async {
        let staleLease =
            activeConversationLease
        crankRadioRemoved(reason: reason)
        await dictation.cancel(reason: reason)
        if let staleLease {
            await StoryInteractionArbiter
                .shared
                .release(
                    staleLease,
                    reason:
                        "crankRadioShutdown.\(reason)"
                )
        }
    }
}
