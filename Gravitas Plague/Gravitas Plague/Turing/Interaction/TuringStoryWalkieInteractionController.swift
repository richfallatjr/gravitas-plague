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
        armIfReady(
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
        armIfReady(reason: "walkieInstalled")
    }

    func walkieRemoved(reason: String) {
        walkieReady = false
        holdActive = false
        dictationStartTask?.cancel()
        dictationStartTask = nil
        iconController.remove()

        print("""
        [TuringWalkieState] removed
          reason: \(reason)
        """)
    }

    func playTapped(source: String) {
        guard activeEpisodeID == .prologue,
              walkieReady,
              gate.claimPlay(reason: source) else {
            return
        }

        renderGateState(reason: "playClaimed.\(source)")
        print("""
        [TuringWalkieState] play accepted
          source: \(source)
          scriptPointID: prologue.scriptPoint01
        """)

        playStartTask?.cancel()
        playStartTask = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await self.episodeFlow.start(
                scriptPointID: "prologue.scriptPoint01",
                trigger: .userPlay
            )

            guard result.succeeded == false else {
                return
            }

            self.gate.restorePlayAfterFailedClaim(
                reason: "scriptPoint01Failed.\(source)"
            )
        }
    }

    func microphoneHoldBegan(source: String) {
        guard walkieReady,
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
                    self.eventSink?
                        .publishTuringDictationEvent(
                            .failed(result.pickerStatus)
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

    private func armIfReady(reason: String) {
        guard activeEpisodeID == .prologue,
              walkieReady else {
            return
        }

        gate.armPlay(reason: reason)
        renderGateState(reason: "playArm.\(reason)")
    }

    private func renderGateState(reason: String) {
        let presentation = walkieReady
            ? TuringStoryWalkiePresentation(gate: gate.state)
            : .hidden
        iconController.apply(presentation)

        print("""
        [TuringWalkieState] transition
          gate: \(gate.state.rawValue)
          presentation: \(String(describing: presentation))
          walkieReady: \(walkieReady)
          iconVisible: \(presentation != .hidden)
          physicalInteractionEnabled: \(presentation != .hidden)
          reason: \(reason)
        """)
    }
}
