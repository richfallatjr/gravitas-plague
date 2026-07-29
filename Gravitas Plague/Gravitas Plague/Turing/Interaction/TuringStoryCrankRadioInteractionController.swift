import Foundation
import RealityKit

@MainActor
final class TuringStoryCrankRadioInteractionController:
    StoryInteractionSurfacePresenting
{
    private let scriptPointID =
        "prologue.crankRadioBroadcast.001"
    private let conversationKey =
        "object.crank_radio"
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

    private weak var eventSink:
        (any TuringStoryWalkieInteractionEventSink)?

    private var ready = false
    private var holdActive = false
    private var playClaimPending = false
    private var activeConversationLease:
        StoryInteractionLease?
    private var activeRecordingRunID: UUID?
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
                TuringCrankRadioTuningLoopActor.shared
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
            TuringCrankRadioTuningLoopActor
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
        if gate.state(for: .crankRadio) ==
            .closed {
            gate.armPlay(
                surfaceID: .crankRadio,
                reason: "crankRadioInstalled"
            )
        }
        applyInteractionSnapshot(
            latestSnapshot
        )
    }

    func crankRadioRemoved(reason: String) {
        let staleLease =
            activeConversationLease
        let staleRunID =
            activeRecordingRunID
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
            await TuringConversationInputStore
                .shared
                .clear(
                    key: self.conversationKey
                )
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
            let result =
                await self.episodeFlow.start(
                    scriptPointID:
                        self.scriptPointID,
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
                [TuringCrankRadioConversation] dictation tuning started
                  conversationRunID: \(runID.uuidString)
                """)
                await self.dictation
                    .beginHoldToRecord()
            }
    }

    func microphoneHoldEnded(
        source: String
    ) {
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

        let conversationRunID =
            activeRecordingRunID ?? UUID()
        activeConversationLease = nil
        activeRecordingRunID = nil

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
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .processingStarted(
                                finalTranscript:
                                    transcript
                            )
                        )
                    print("""
                    [TuringCrankRadio] conversation submitted
                      characterID: broadcaster
                      outputRoute: \(TuringVoiceOutputContext.crankRadioSpatial.rawValue)
                      conversationKey: \(self.conversationKey)
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
                                            TuringBroadcasterVoiceIdentity
                                                .characterID,
                                        outputRoute:
                                            .crankRadioSpatial,
                                        conversationKey:
                                            self.conversationKey,
                                        playerDictation:
                                            transcript,
                                        interactionLease:
                                            lease,
                                        interactionSurface:
                                            .crankRadio
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
