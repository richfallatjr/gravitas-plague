import Foundation
import RealityKit

@MainActor
final class TuringStoryDadFrameInteractionController:
    StoryInteractionSurfacePresenting
{
    private let scriptPointID =
        "prologue.dadPhotoMemory.001"
    private let conversationKey =
        "object.dad_frame"
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
        if gate.state(for: .dadFrame) == .closed {
            gate.armPlay(
                surfaceID: .dadFrame,
                reason: "dadFrameInstalled"
            )
        }
        applyInteractionSnapshot(latestSnapshot)
    }

    func dadFrameRemoved(reason: String) {
        ready = false
        holdActive = false
        playClaimPending = false
        playTask?.cancel()
        dictationStartTask?.cancel()
        conversationTask?.cancel()
        playTask = nil
        dictationStartTask = nil
        conversationTask = nil
        iconController.remove()
        print("[TuringDadFrame] removed reason=\(reason)")
    }

    func playTapped(source: String) {
        guard ready,
              playClaimPending == false,
              latestSnapshot.capabilities
                .contains(.dadFramePlay) else {
            return
        }

        playClaimPending = true
        print("""
        [TuringDadPhoto] play claimed
          scriptPointID: \(scriptPointID)
          interactionSurface: \(StoryInteractionSurfaceID.dadFrame.rawValue)
          conversationKey: \(conversationKey)
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
                scriptPointID: self.scriptPointID,
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
            dictationStartTask?.cancel()
            dictationStartTask = nil
            let lease = activeConversationLease
            let runID = activeRecordingRunID
            activeConversationLease = nil
            activeRecordingRunID = nil
            Task {
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
            }
            return
        }

        guard let lease = activeConversationLease else {
            gate.ensureMicrophoneAvailable(
                surfaceID: .dadFrame,
                reason: "dadFrameConversationLeaseMissing"
            )
            return
        }
        let conversationRunID =
            activeRecordingRunID ?? UUID()
        activeConversationLease = nil
        activeRecordingRunID = nil

        conversationTask?.cancel()
        conversationTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let transcript =
                    try await self.dictation.endHoldToSend()
                self.eventSink?.publishTuringDictationEvent(
                    .processingStarted(
                        finalTranscript: transcript
                    )
                )
                print("""
                [TuringDadPhoto] conversation submitted
                  characterID: rich
                  outputRoute: \(TuringVoiceOutputContext.roomGlobal.rawValue)
                  conversationKey: \(self.conversationKey)
                  userInputUTF16: \(transcript.utf16.count)
                  dialogueHistoryIncluded: false
                """)

                let result =
                    await TuringFlowConversationRunner.run(
                        request:
                            TuringFlowConversationRequest(
                                characterID: "rich",
                                outputRoute: .roomGlobal,
                                conversationKey:
                                    self.conversationKey,
                                playerDictation: transcript,
                                interactionLease: lease,
                                interactionSurface:
                                    .dadFrame
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
}
