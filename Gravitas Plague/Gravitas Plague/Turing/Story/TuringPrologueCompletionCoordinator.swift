import Foundation

@MainActor
final class TuringPrologueCompletionCoordinator: TuringStoryCompletionEventSink {
    private let progress: TuringStoryProgressStore
    private let postBattleProgress: TuringProloguePostBattleProgressStore
    private let postBattleActivations: TuringProloguePostBattleActivationRegistry
    private let battleRouter: PrologueStoryActionRouter
    private let gate: TuringFlowInteractionGateController
    private unowned let walkie: TuringStoryWalkieInteractionController
    private unowned let dadFrame: TuringStoryDadFrameInteractionController
    private unowned let hamReceiver: TuringStoryHamReceiverInteractionController
    private var handledEventIDs = Set<UUID>()
    private var episodeBoundaryRequested = false

    var onEpisodeBoundary: ((StoryEpisodeBoundaryEvent) async throws -> Void)?

    init(
        progress: TuringStoryProgressStore = .shared,
        postBattleProgress: TuringProloguePostBattleProgressStore = .shared,
        postBattleActivations: TuringProloguePostBattleActivationRegistry = .shared,
        battleRouter: PrologueStoryActionRouter,
        gate: TuringFlowInteractionGateController = .shared,
        walkie: TuringStoryWalkieInteractionController,
        dadFrame: TuringStoryDadFrameInteractionController,
        hamReceiver: TuringStoryHamReceiverInteractionController
    ) {
        self.progress = progress
        self.postBattleProgress = postBattleProgress
        self.postBattleActivations = postBattleActivations
        self.battleRouter = battleRouter
        self.gate = gate
        self.walkie = walkie
        self.dadFrame = dadFrame
        self.hamReceiver = hamReceiver
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws -> TuringStoryCompletionDisposition {
        guard handledEventIDs.contains(event.eventID) == false else {
            return .useDescriptorProgression
        }

        switch event.scriptPointID {
        case "prologue.scriptPoint01":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script01PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
        case "prologue.scriptPoint02":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script02PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
        case "prologue.scriptPoint03":
            try progress.commit(
                episodeID: .prologue,
                checkpoint: .script03PromptVoiceCompleted,
                sourceEventID: event.eventID,
                contentRevision: TuringStoryProgressStore.prologueContentRevision
            )
            try await battleRouter.scriptPointCompleted(event)
        default:
            guard let contract = TuringProloguePostBattleDeviceCatalog
                .byTerminalScriptPointID[event.scriptPointID] else {
                handledEventIDs.insert(event.eventID)
                return .useDescriptorProgression
            }

            let activation = try await postBattleActivations
                .consumeValidatedCompletion(event: event, contract: contract)
            let evidence = ProloguePostBattleCompletionEvidence.Live(
                deviceID: contract.deviceID,
                rootScriptPointID: contract.rootScriptPointID,
                terminalScriptPointID: contract.terminalScriptPointID,
                activationID: activation.activationID,
                flowSequenceID: event.flowSequenceID,
                flowInstanceID: event.flowInstanceID,
                terminalCompletionEventID: event.eventID,
                triggerDescription: event.triggerSource.logValue,
                actualTerminalPlaybackCompletedAt: Date()
            )
            let transaction = try await postBattleProgress.completeDevice(
                evidence: evidence
            )
            handledEventIDs.insert(event.eventID)

            guard transaction.becameChapterTransitionPending,
                  let boundaryEvent = transaction.boundaryEvent else {
                try await applyPostBattleHub(
                    transaction.snapshot,
                    reason: "deviceCompleted.\(contract.deviceID.rawValue)"
                )
                return .suppressDescriptorGateAndReleaseInteraction
            }

            guard transaction.snapshot.allDevicesCompleted,
                  transaction.snapshot.boundaryState == .chapterTransitionPending,
                  transaction.snapshot.boundaryEventID == boundaryEvent.eventID else {
                throw TuringRuntimeError.invalidConfig(
                    "Chapter 1 transition was requested before all four Prologue devices were durable."
                )
            }

            print("""
            [ProloguePostBattleHub] boundary accepted
              walkieState: \(transaction.snapshot.state(for: .walkie).rawValue)
              dadPhotoState: \(transaction.snapshot.state(for: .dadPhoto).rawValue)
              crankRadioState: \(transaction.snapshot.state(for: .crankRadio).rawValue)
              hamReceiverState: \(transaction.snapshot.state(for: .hamReceiver).rawValue)
              boundaryState: \(transaction.snapshot.boundaryState.rawValue)
              boundaryEventID: \(boundaryEvent.eventID.uuidString)
              allFourActuallyCompleted: true
            """)

            await closePostBattleHub(
                reason: "allDevicesCompleted.\(event.eventID.uuidString)"
            )
            await publishEpisodeBoundary(boundaryEvent)
            return .interactionLeaseTransferred
        }

        handledEventIDs.insert(event.eventID)
        return .useDescriptorProgression
    }

    func battleRuntimeReleased(
        _ event: BattleRuntimeReleasedEvent
    ) async throws {
        guard event.releaseReport.battleInstanceID == event.battleInstanceID,
              event.releaseReport.allHeavyEnemyRuntimesReleased,
              event.releaseReport.allEnemyControllersReleased,
              event.releaseReport.fullPortalReleased else {
            throw TuringRuntimeError.invalidConfig(
                "Battle01 runtime was not fully released before the Prologue post-battle hub."
            )
        }
        let snapshot = try await postBattleProgress
            .unlockAfterBattleRuntimeReleased()
        switch snapshot.boundaryState {
        case .notReady:
            try await applyPostBattleHub(
                snapshot,
                reason: "battleRuntimeReleased.\(event.battleInstanceID.uuidString)"
            )
        case .chapterTransitionPending:
            await closePostBattleHub(reason: "pendingChapterBoundary")
            print(
                "[TuringProloguePostBattle] pending Chapter boundary retained; " +
                    "Continue will retry without replaying a device"
            )
        case .chapter01Started:
            await closePostBattleHub(reason: "chapter01AlreadyStarted")
        }
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        guard handledEventIDs.contains(event.eventID) == false else { return }
        guard event.parentScriptPointID == "prologue.scriptPoint01" else {
            return
        }
        try progress.commit(
            episodeID: .prologue,
            checkpoint: .script01ConversationVoiceCompleted,
            sourceEventID: event.eventID,
            contentRevision: TuringStoryProgressStore.prologueContentRevision
        )
        handledEventIDs.insert(event.eventID)
    }

    func reset(reason: String) {
        handledEventIDs.removeAll(keepingCapacity: false)
        episodeBoundaryRequested = false
        battleRouter.reset(reason: reason)
    }

    func commitPendingEpisodeBoundary() async throws {
        _ = try await postBattleProgress.markPendingChapter01Started()
    }

    func episodeBoundaryFailed(reason: String) async {
        episodeBoundaryRequested = false
        await closePostBattleHub(reason: "episodeBoundaryFailed.\(reason)")
        print(
            "[TuringProloguePostBattle] Chapter transition failed; " +
                "all four completions remain durable reason=\(reason)"
        )
    }

    private func applyPostBattleHub(
        _ snapshot: ProloguePostBattleSnapshot,
        reason: String
    ) async throws {
        guard snapshot.hubUnlocked,
              snapshot.boundaryState == .notReady else {
            throw TuringRuntimeError.invalidConfig(
                "The Prologue device hub cannot be restored from \(snapshot.boundaryState.rawValue)."
            )
        }
        // Keep logical bindings staged for the authored sequence. Optional live
        // microphones are presented independently from these latent gates.
        walkie.stageBinding(
            .prologuePostBattleWalkie,
            initialState: .closed,
            reason: reason
        )
        walkie.stagePendingPlayAction(
            snapshot.state(for: .walkie) == .play
                ? .startScriptPoint(
                    id: TuringProloguePostBattleDeviceCatalog.walkie
                        .rootScriptPointID,
                    trigger: .userPlay
                )
                : nil,
            reason: reason
        )
        dadFrame.stageBinding(.prologueDadPhoto, reason: reason)
        hamReceiver.stageBinding(.prologueHamReceiver, reason: reason)
        await gate.applyStableStatesAtomically(
            gateStates(for: snapshot),
            reason: "prologuePostBattleHub.\(reason).revision.\(snapshot.revision)"
        )
        if let nextID = snapshot.nextRequiredDevice(
            ordered: TuringProloguePostBattleDeviceCatalog.ordered
        ), let contract = TuringProloguePostBattleDeviceCatalog.byID[nextID] {
            StoryModeActionCoordinator.shared.activate(
                .init(
                    episodeID: .prologue,
                    rootScriptPointID: contract.rootScriptPointID,
                    durableBoundaryID:
                        "prologue.postBattle.\(snapshot.revision).\(nextID.rawValue)",
                    sourceEventID: UUID()
                )
            )
        }
        print(
            "[TuringProloguePostBattle] hub restored revision=\(snapshot.revision) " +
                "states=\(stateLog(snapshot))"
        )
    }

    private func closePostBattleHub(reason: String) async {
        await gate.applyStableStatesAtomically(
            Dictionary(
                uniqueKeysWithValues: StoryInteractionSurfaceID.allCases.map {
                    ($0, .closed)
                }
            ),
            reason: "prologuePostBattleHub.closed.\(reason)"
        )
    }

    private func publishEpisodeBoundary(
        _ event: StoryEpisodeBoundaryEvent
    ) async {
        guard episodeBoundaryRequested == false else { return }
        guard let onEpisodeBoundary else {
            await TuringEpisodeFlowController.shared
                .releaseAnyCurrentInteractionAfterTransferFailure(
                    reason: "prologueBoundaryOwnerMissing"
                )
            await episodeBoundaryFailed(reason: "missingRouteOwner")
            return
        }
        episodeBoundaryRequested = true
        do {
            try await onEpisodeBoundary(event)
            print(
                "[TuringProloguePostBattle] all four devices completed; " +
                    "Chapter 01 title card requested boundaryEventID=\(event.eventID.uuidString)"
            )
        } catch {
            await TuringEpisodeFlowController.shared
                .releaseAnyCurrentInteractionAfterTransferFailure(
                    reason: "prologueBoundaryRejected"
                )
            await episodeBoundaryFailed(
                reason: "titleRequestRejected.\(error.localizedDescription)"
            )
        }
    }

    private func stateLog(_ snapshot: ProloguePostBattleSnapshot) -> String {
        ProloguePostBattleDeviceID.allCases.map {
            "\($0.rawValue)=\(snapshot.state(for: $0).rawValue)"
        }.joined(separator: ",")
    }

    private func gateStates(
        for snapshot: ProloguePostBattleSnapshot
    ) -> [StoryInteractionSurfaceID: TuringFlowInteractionGateController.State] {
        let next = snapshot.nextRequiredDevice(
            ordered: TuringProloguePostBattleDeviceCatalog.ordered
        )
        return Dictionary(
            uniqueKeysWithValues:
                TuringProloguePostBattleDeviceCatalog.ordered.map { contract in
                    let state: TuringFlowInteractionGateController.State
                    if snapshot.state(for: contract.deviceID) == .microphone {
                        state = .microphone
                    } else if contract.deviceID == next {
                        state = .play
                    } else {
                        state = .closed
                    }
                    return (contract.interactionSurface, state)
                }
        )
    }
}
