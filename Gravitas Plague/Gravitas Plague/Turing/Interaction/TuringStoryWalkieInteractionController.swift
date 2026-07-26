import Foundation
import RealityKit

@MainActor
protocol TuringStoryWalkieInteractionEventSink: AnyObject {
    func publishTuringDictationEvent(
        _ event: TuringDictationEvent
    )
}

extension PlagueDemoSession:
    TuringStoryWalkieInteractionEventSink
{
}

enum TuringStoryWalkiePlayAction: Sendable, Equatable {
    case startScriptPoint(id: String, trigger: TuringFlowTriggerSource)
}

@MainActor
final class TuringStoryWalkieInteractionController {
    private let gate: TuringFlowInteractionGateController
    private let episodeFlow: TuringEpisodeFlowController
    private let dictation: TuringDictationCoordinator
    private let iconController:
        TuringStoryPropBillboardIconController

    private weak var eventSink:
        (any TuringStoryWalkieInteractionEventSink)?

    private var activeEpisodeID: TuringEpisodeID?
    private var walkieReady = false
    private var holdActive = false
    private var pendingPlayAction: TuringStoryWalkiePlayAction?
    private var activeConversationLease: StoryInteractionLease?
    private var activeRecordingRunID: UUID?
    private var playClaimPending = false
    private var latestInteractionSnapshot = StoryInteractionSnapshot(
        revision: 0,
        turingGate: .closed,
        doorState: .closedUnloaded,
        exclusiveOwner: nil,
        capabilities: [],
        walkiePresentation: .hidden,
        doorPresentation: .hidden
    )

    private var playStartTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var dictationStartTask: Task<Void, Never>?

    init(
        gate: TuringFlowInteractionGateController = .shared,
        episodeFlow: TuringEpisodeFlowController = .shared,
        dictation: TuringDictationCoordinator? = nil,
        iconController:
            TuringStoryPropBillboardIconController? = nil,
        eventSink:
            (any TuringStoryWalkieInteractionEventSink)? = nil
    ) {
        self.gate = gate
        self.episodeFlow = episodeFlow
        self.dictation = dictation ??
            TuringDictationCoordinator()
        self.iconController = iconController ??
            TuringStoryPropBillboardIconController()
        self.eventSink = eventSink

        self.dictation.onEvent = { [weak self] event in
            self?.eventSink?
                .publishTuringDictationEvent(event)
        }
    }

    func setEventSink(
        _ eventSink:
            (any TuringStoryWalkieInteractionEventSink)?
    ) {
        self.eventSink = eventSink
    }

    func episodeStarted(_ episodeID: TuringEpisodeID) {
        activeEpisodeID = episodeID
        applyInteractionSnapshot(latestInteractionSnapshot)
    }

    func walkieInstalled(
        iconAnchor: Entity,
        walkieRoot: Entity
    ) {
        iconController.install(
            iconAnchor: iconAnchor,
            walkieRoot: walkieRoot
        )
        walkieReady = true

        print("""
        [TuringWalkieState] installed
          iconAnchor: \(iconAnchor.name)
          walkieRoot: \(walkieRoot.name)
          physicalTarget: TuringStoryWalkieTalkie_PhysicalHitTarget
        """)

        applyInteractionSnapshot(latestInteractionSnapshot)
    }

    func armPlay(action: TuringStoryWalkiePlayAction, reason: String) {
        guard walkieReady else {
            print("[TuringWalkieState] play arm rejected reason=walkieNotInstalled source=\(reason)")
            return
        }
        pendingPlayAction = action
        gate.forcePlayForStoryTeleport(reason: reason)
    }

    func armMicrophone(reason: String) {
        guard walkieReady else {
            print("[TuringWalkieState] microphone arm rejected reason=walkieNotInstalled source=\(reason)")
            return
        }
        pendingPlayAction = nil
        gate.forceMicrophoneForStoryTeleport(reason: reason)
    }

    func hideForStoryTeleport(reason: String) {
        pendingPlayAction = nil
        gate.forceClosedForStoryTeleport(reason: reason)
    }

    func setBattle01GrandmaMemoryPresent(
        _ present: Bool,
        reason: String
    ) {
        print("""
        [TuringWalkieState] Battle01 memory telemetry changed
          grandmaMemoryPresent: \(present)
          gatePreserved: \(gate.state.rawValue)
          presentationOwner: StoryInteractionArbiter
          reason: \(reason)
        """)
    }

    func walkieRemoved(reason: String) {
        walkieReady = false
        holdActive = false
        pendingPlayAction = nil
        dictationStartTask?.cancel()
        dictationStartTask = nil
        iconController.remove()

        print("""
        [TuringWalkieState] removed
          reason: \(reason)
        """)
    }

    func playTapped(source: String) {
        guard walkieReady,
              let action = pendingPlayAction,
              playClaimPending == false,
              latestInteractionSnapshot.capabilities.contains(.walkiePlay) else {
            return
        }

        playClaimPending = true
        pendingPlayAction = nil

        playStartTask?.cancel()
        playStartTask = Task { [weak self, action] in
            guard let self else {
                return
            }
            defer { self.playClaimPending = false }

            let result: TuringVoiceRunResult
            let scriptPointID: String
            switch action {
            case .startScriptPoint(let id, let trigger):
                scriptPointID = id
                print("""
                [TuringWalkieState] play accepted
                  source: \(source)
                  scriptPointID: \(id)
                  trigger: \(trigger.logValue)
                """)
                if case .continuationRestore(let checkpoint) = trigger {
                    result = await self.episodeFlow.startFromContinuation(
                        scriptPointID: id,
                        checkpoint: checkpoint
                    )
                } else {
                    result = await self.episodeFlow.start(
                        scriptPointID: id,
                        trigger: trigger
                    )
                }
            }

            guard result.succeeded == false else {
                return
            }

            self.pendingPlayAction = action
            self.gate.restorePlayAfterFailedClaim(
                reason: "\(scriptPointID)Failed.\(source)"
            )
        }
    }

    func quiesceForStoryTeleport(reason: String) async {
        holdActive = false
        pendingPlayAction = nil
        playStartTask?.cancel()
        conversationTask?.cancel()
        dictationStartTask?.cancel()
        playStartTask = nil
        conversationTask = nil
        dictationStartTask = nil
        await dictation.cancel(reason: reason)
        await TuringWalkieCommsFXController.shared.stopAll(reason: reason)
        if let endpoint = TuringStoryWalkieAudioRoute.makeActiveEndpoint() {
            await endpoint.stopAll(reason: reason)
        }
        gate.forceClosedForStoryTeleport(reason: reason)
        print("[TuringWalkieState] quiesced for Story teleport reason=\(reason)")
    }

    func microphoneHoldBegan(source: String) {
        guard walkieReady,
              latestInteractionSnapshot.capabilities.contains(.walkieMicrophone),
              holdActive == false else {
            return
        }

        holdActive = true
        dictationStartTask?.cancel()
        dictationStartTask = Task { [weak self] in
            guard let self else {
                return
            }

            let recordingRunID = UUID()
            let lease: StoryInteractionLease
            do {
                lease = try await TuringHighMemoryPreflightCoordinator.shared
                    .acquireInteractionLease(
                        runID: "conversation.\(recordingRunID.uuidString)",
                        source: "microphoneHold.\(source)",
                        mode: .manual
                    )
            } catch {
                self.holdActive = false
                self.eventSink?.publishTuringDictationEvent(
                    .failed("Device operation failed: \(error.localizedDescription)")
                )
                return
            }

            guard self.holdActive,
                  Task.isCancelled == false else {
                await StoryInteractionArbiter.shared.release(
                    lease,
                    reason: "holdEndedBeforeLeaseUse"
                )
                return
            }
            self.activeConversationLease = lease
            self.activeRecordingRunID = recordingRunID
            self.gate.beginConversation(conversationRunID: recordingRunID)

            await TuringWalkieCommsFXController.shared
                .playOpenCommBeforeRecording(
                    reason: "prologueMic.\(source)"
                )

            guard self.holdActive,
                  Task.isCancelled == false else {
                await self.dictation.cancel(
                    reason: "holdEndedBeforeRecording"
                )
                self.activeConversationLease = nil
                self.activeRecordingRunID = nil
                await StoryInteractionArbiter.shared.release(
                    lease,
                    reason: "holdEndedBeforeRecording"
                )
                self.gate.restoreMicrophoneAfterConversation(
                    conversationRunID: recordingRunID
                )
                return
            }

            await self.dictation.beginHoldToRecord()
        }

        print("""
        [TuringWalkieState] microphone hold began
          source: \(source)
        """)
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
            let recordingRunID = activeRecordingRunID
            activeConversationLease = nil
            activeRecordingRunID = nil
            Task {
                if let lease {
                    await StoryInteractionArbiter.shared.release(
                        lease,
                        reason: "holdEndedBeforeRecording"
                    )
                }
                if let recordingRunID {
                    gate.restoreMicrophoneAfterConversation(
                        conversationRunID: recordingRunID
                    )
                }
            }
            print("""
            [TuringWalkieState] microphone hold ended before recording
              source: \(source)
            """)
            return
        }

        dictationStartTask = nil
        guard let interactionLease = activeConversationLease else {
            gate.ensureMicrophoneAvailable(reason: "conversationLeaseMissing")
            return
        }
        activeConversationLease = nil
        activeRecordingRunID = nil
        conversationTask?.cancel()
        conversationTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let transcript = try await self.dictation
                    .endHoldToSend()
                self.eventSink?
                    .publishTuringDictationEvent(
                        .processingStarted(
                            finalTranscript: transcript
                        )
                    )

                await TuringWalkieCommsFXController.shared
                    .playSendCommAndStartSendingLeadIn(
                        reason: "prologueMic.\(source)"
                    )

                let result = await TuringBigMikeConversationRunner.run(
                    playerDictation: transcript,
                    interactionLease: interactionLease,
                    inputStore: .shared,
                    onSegmentZeroReady: { [weak self] in
                        self?.eventSink?
                            .publishTuringDictationEvent(
                                .responseSegmentZeroReady(
                                    clearAfterSeconds: 2.0
                                )
                            )
                    }
                )

                if result.succeeded {
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .responseAudioFinished
                        )
                } else {
                    print("""
                    [TuringWalkieState] downstream response failed
                      source: \(source)
                      dictationSucceeded: true
                      error: \(result.pickerStatus)
                    """)
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .responseFailed(
                                result.pickerStatus
                            )
                        )
                }
            } catch {
                await StoryInteractionArbiter.shared.release(
                    interactionLease,
                    reason: "dictationFailedBeforeConversation"
                )
                await TuringWalkieCommsFXController.shared
                    .stopSendingLeadIn(
                        reason: "prologueMicFailed"
                    )
                await TuringWalkieCommsFXController.shared
                    .stopAmbientWalkieStatic(
                        reason: "prologueMicFailed"
                    )
                self.eventSink?
                    .publishTuringDictationEvent(
                        .failed(error.localizedDescription)
                    )
            }
        }

        print("""
        [TuringWalkieState] microphone hold ended
          source: \(source)
          dispatch: conversationVoice
        """)
    }

    func shutdown(reason: String) async {
        walkieReady = false
        activeEpisodeID = nil
        holdActive = false
        pendingPlayAction = nil
        let staleConversationLease = activeConversationLease
        activeConversationLease = nil
        activeRecordingRunID = nil
        playClaimPending = false

        playStartTask?.cancel()
        conversationTask?.cancel()
        dictationStartTask?.cancel()
        playStartTask = nil
        conversationTask = nil
        dictationStartTask = nil

        await dictation.cancel(reason: reason)
        if let staleConversationLease {
            await StoryInteractionArbiter.shared.release(
                staleConversationLease,
                reason: "walkieShutdown.\(reason)"
            )
        }
        await TuringWalkieCommsFXController.shared
            .stopAll(reason: reason)

        iconController.remove()

        print("""
        [TuringWalkieState] shutdown
          reason: \(reason)
        """)
    }

}

extension TuringStoryWalkieInteractionController:
    StoryInteractionSurfacePresenting
{
    func applyInteractionSnapshot(
        _ snapshot: StoryInteractionSnapshot
    ) {
        latestInteractionSnapshot = snapshot
        guard walkieReady else {
            iconController.apply(.hidden)
            return
        }

        switch snapshot.walkiePresentation {
        case .hidden:
            iconController.apply(.hidden)
        case .play:
            iconController.apply(.play)
        case .microphone:
            iconController.apply(.microphone)
        }

        print("""
        [TuringWalkieState] arbiter presentation
          revision: \(snapshot.revision)
          presentation: \(snapshot.walkiePresentation.rawValue)
          iconVisible: \(snapshot.walkiePresentation != .hidden)
          physicalInteractionEnabled: \(snapshot.walkiePresentation != .hidden)
        """)
    }
}
