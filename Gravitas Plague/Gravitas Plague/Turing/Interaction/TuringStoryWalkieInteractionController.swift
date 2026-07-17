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
    private var battle01GrandmaMemoryPresent = false

    private var playStartTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var dictationStartTask: Task<Void, Never>?
    private var gateObserver: NSObjectProtocol?

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
        startObservingIfNeeded()
    }

    func setEventSink(
        _ eventSink:
            (any TuringStoryWalkieInteractionEventSink)?
    ) {
        self.eventSink = eventSink
    }

    func episodeStarted(_ episodeID: TuringEpisodeID) {
        startObservingIfNeeded()
        activeEpisodeID = episodeID
        renderGateState(
            reason: "episodeStarted.\(episodeID.rawValue)"
        )
    }

    func walkieInstalled(
        iconAnchor: Entity,
        walkieRoot: Entity
    ) {
        startObservingIfNeeded()
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

        renderGateState(reason: "walkieInstalled")
    }

    func armPlay(action: TuringStoryWalkiePlayAction, reason: String) {
        guard walkieReady else {
            print("[TuringWalkieState] play arm rejected reason=walkieNotInstalled source=\(reason)")
            return
        }
        pendingPlayAction = action
        gate.forcePlayForStoryTeleport(reason: reason)
        renderGateState(reason: reason)
    }

    func armMicrophone(reason: String) {
        guard walkieReady else {
            print("[TuringWalkieState] microphone arm rejected reason=walkieNotInstalled source=\(reason)")
            return
        }
        pendingPlayAction = nil
        gate.forceMicrophoneForStoryTeleport(reason: reason)
        renderGateState(reason: reason)
    }

    func hideForStoryTeleport(reason: String) {
        pendingPlayAction = nil
        gate.forceClosedForStoryTeleport(reason: reason)
        renderGateState(reason: reason)
    }

    func setBattle01GrandmaMemoryPresent(
        _ present: Bool,
        reason: String
    ) {
        guard battle01GrandmaMemoryPresent != present else {
            return
        }
        battle01GrandmaMemoryPresent = present
        renderGateState(reason: "battle01GrandmaMemory.\(reason)")

        print("""
        [TuringWalkieState] Battle01 memory suppression changed
          grandmaMemoryPresent: \(present)
          gatePreserved: \(gate.state.rawValue)
          billboardSuppressed: \(present)
          physicalInteractionSuppressed: \(present)
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
              battle01GrandmaMemoryPresent == false,
              let action = pendingPlayAction,
              gate.claimPlay(reason: source) else {
            return
        }

        pendingPlayAction = nil

        renderGateState(reason: "playClaimed.\(source)")

        playStartTask?.cancel()
        playStartTask = Task { [weak self, action] in
            guard let self else {
                return
            }

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
        renderGateState(reason: reason)
        print("[TuringWalkieState] quiesced for Story teleport reason=\(reason)")
    }

    func microphoneHoldBegan(source: String) {
        guard walkieReady,
              battle01GrandmaMemoryPresent == false,
              gate.microphoneEnabled,
              holdActive == false else {
            return
        }

        holdActive = true
        dictationStartTask?.cancel()
        dictationStartTask = Task { [weak self] in
            guard let self else {
                return
            }

            await TuringWalkieCommsFXController.shared
                .playOpenCommBeforeRecording(
                    reason: "prologueMic.\(source)"
                )

            guard self.holdActive,
                  self.gate.microphoneEnabled,
                  Task.isCancelled == false else {
                await self.dictation.cancel(
                    reason: "holdEndedBeforeRecording"
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
            print("""
            [TuringWalkieState] microphone hold ended before recording
              source: \(source)
            """)
            return
        }

        dictationStartTask = nil
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
                    seedStore: .shared,
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
        battle01GrandmaMemoryPresent = false

        playStartTask?.cancel()
        conversationTask?.cancel()
        dictationStartTask?.cancel()
        playStartTask = nil
        conversationTask = nil
        dictationStartTask = nil

        await dictation.cancel(reason: reason)
        await TuringWalkieCommsFXController.shared
            .stopAll(reason: reason)

        if let gateObserver {
            NotificationCenter.default
                .removeObserver(gateObserver)
            self.gateObserver = nil
        }
        iconController.remove()

        print("""
        [TuringWalkieState] shutdown
          reason: \(reason)
        """)
    }

    private func startObservingIfNeeded() {
        guard gateObserver == nil else {
            return
        }

        gateObserver = NotificationCenter.default.addObserver(
            forName: .turingFlowInteractionGateChanged,
            object: gate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.renderGateState(reason: "gateChanged")
            }
        }
    }

    private func renderGateState(reason: String) {
        let presentation = walkieReady && battle01GrandmaMemoryPresent == false
            ? TuringStoryWalkiePresentation(gate: gate.state)
            : .hidden
        iconController.apply(presentation)

        print("""
        [TuringWalkieState] transition
          gate: \(gate.state.rawValue)
          presentation: \(String(describing: presentation))
          walkieReady: \(walkieReady)
          battle01GrandmaMemoryPresent: \(battle01GrandmaMemoryPresent)
          iconVisible: \(presentation != .hidden)
          physicalInteractionEnabled: \(presentation != .hidden)
          reason: \(reason)
        """)
    }
}
