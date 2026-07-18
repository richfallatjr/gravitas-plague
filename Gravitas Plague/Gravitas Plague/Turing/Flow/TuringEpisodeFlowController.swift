import Foundation

struct TuringScriptPointCompletionEvent: Sendable, Equatable {
    let eventID: UUID
    let scriptPointID: String
    let flowInstanceID: UUID
    let triggerSource: TuringFlowTriggerSource
}

struct TuringConversationPlaybackCompletionEvent: Sendable, Equatable {
    let eventID: UUID
    let conversationRunID: UUID
    let conversationKey: String
    let parentScriptPointID: String
}

@MainActor
protocol TuringPrologueCompletionEventSink: AnyObject {
    func scriptPointCompleted(_ event: TuringScriptPointCompletionEvent) async throws
    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws
}

actor TuringEpisodeFlowController {
    static let shared =
        TuringEpisodeFlowController()

    private struct PendingConversationAdvance {
        let parentScriptPointID: String
        let nextScriptPointID: String
        let conversationKey: String
    }

    private let engine: TuringFlowEngine
    private let descriptorStore:
        any TuringFlowDescriptorLoading
    private let seedStore:
        TuringConversationSeedStore
    private let catalogValidator:
        (any TuringFlowCatalogValidating)?
    private let interactionPreflight:
        TuringHighMemoryPreflightCoordinator
    private let interactionArbiter:
        StoryInteractionArbiter

    private var activeSequenceID: UUID?
    private var catalogValidated = false
    private var completedScriptPointIDs =
        Set<String>()
    private var pendingConversationAdvance:
        PendingConversationAdvance?
    private var activeInteractionLease:
        StoryInteractionLease?
    private weak var completionEventSink:
        (any TuringPrologueCompletionEventSink)?

    init(
        engine: TuringFlowEngine = .shared,
        descriptorStore:
            any TuringFlowDescriptorLoading =
                TuringFlowDescriptorStore(),
        seedStore:
            TuringConversationSeedStore = .shared,
        interactionPreflight:
            TuringHighMemoryPreflightCoordinator = .shared,
        interactionArbiter:
            StoryInteractionArbiter = .shared,
        catalogValidator:
            (any TuringFlowCatalogValidating)? =
                TuringFlowCatalogValidator()
    ) {
        self.engine = engine
        self.descriptorStore = descriptorStore
        self.seedStore = seedStore
        self.interactionPreflight = interactionPreflight
        self.interactionArbiter = interactionArbiter
        self.catalogValidator = catalogValidator
    }

    func setCompletionEventSink(
        _ sink: (any TuringPrologueCompletionEventSink)?
    ) {
        completionEventSink = sink
    }

    func start(
        scriptPointID: String,
        trigger: TuringFlowTriggerSource,
        allowExplicitReplay: Bool = false
    ) async -> TuringVoiceRunResult {
        guard activeSequenceID == nil else {
            return .failed(
                "Ignored \(scriptPointID): another Turing Flow sequence is active."
            )
        }

        let sequenceID = UUID()
        activeSequenceID = sequenceID
        let result = await runSequence(
            scriptPointID: scriptPointID,
            trigger: trigger,
            allowExplicitReplay: allowExplicitReplay,
            sequenceID: sequenceID
        )
        if activeSequenceID == sequenceID {
            activeSequenceID = nil
        }
        await finishInteractionLease(
            reason: "sequenceFinished.\(sequenceID.uuidString).\(scriptPointID)"
        )
        return result
    }

    private func runSequence(
        scriptPointID: String,
        trigger: TuringFlowTriggerSource,
        allowExplicitReplay: Bool,
        sequenceID: UUID
    ) async -> TuringVoiceRunResult {
        if catalogValidated == false,
           let catalogValidator {
            do {
                try await catalogValidator
                    .validate()
                catalogValidated = true
            } catch {
                return .failed(
                    "Turing Flow catalog validation failed: \(error.localizedDescription)"
                )
            }
        }

        if completedScriptPointIDs.contains(
            scriptPointID
        ),
           allowExplicitReplay == false {
            return .failed(
                "Ignored \(scriptPointID): it is already completed for this episode."
            )
        }

        do {
            if let adoptedLease = activeInteractionLease {
                try await interactionArbiter.requireCurrent(adoptedLease)
            } else {
                let claimedLease = try await interactionPreflight
                    .acquireInteractionLease(
                        runID: sequenceID.uuidString,
                        source: trigger.logValue,
                        mode: trigger.interactionStartMode
                    )
                activeInteractionLease = claimedLease
            }
        } catch {
            return .failed(
                "Device operation failed: \(error.localizedDescription)"
            )
        }

        var scheduledPointID =
            scriptPointID
        var scheduledTrigger = trigger
        while true {
            if scheduledPointID != scriptPointID,
               allowExplicitReplay == false,
               completedScriptPointIDs.contains(
                   scheduledPointID
               ) {
                return .failed(
                    "Ignored \(scheduledPointID): it is already completed for this episode."
                )
            }
            let descriptor:
                TuringFlowDescriptor

            do {
                descriptor =
                    try descriptorStore.require(
                        scheduledPointID
                    )
            } catch {
                return .failed(
                    "Could not schedule \(scheduledPointID): \(error.localizedDescription)"
                )
            }

            if descriptor.trigger.delaySeconds > 0 {
                do {
                    try await Task.sleep(
                        for: .seconds(
                            descriptor.trigger
                                .delaySeconds
                        )
                    )
                } catch {
                    return .failed(
                        "Cancelled before \(scheduledPointID) started."
                    )
                }
            }

            let result = await engine.run(
                scriptPointID:
                    scheduledPointID,
                trigger: scheduledTrigger
            )
            guard result.succeeded else {
                // A previously completed parent stays completed. The failed
                // next point may be retried explicitly by its own ID.
                return result.voiceRunResult
            }

            do {
                try await publishCompletion(
                    result: result,
                    scriptPointID: scheduledPointID,
                    triggerSource: scheduledTrigger
                )
            } catch {
                return .failed(
                    "\(scheduledPointID) completed playback, but its checkpoint could not be saved: \(error.localizedDescription)"
                )
            }

            completedScriptPointIDs.insert(scheduledPointID)

            let progression =
                descriptor.progression

            guard let nextScriptPointID =
                    progression.nextScriptPointID else {
                pendingConversationAdvance = nil
                if progression
                    .interactionGateAfterCompletion ==
                    .microphone {
                    await TuringFlowInteractionGateController
                        .shared
                        .ensureMicrophoneAvailable(
                            reason:
                                "terminalPointCompleted.\(descriptor.scriptPointID)"
                        )
                }
                return result.voiceRunResult
            }

            let nextDescriptor:
                TuringFlowDescriptor

            do {
                nextDescriptor =
                    try descriptorStore.require(
                        nextScriptPointID
                    )
            } catch {
                print("""
                [TuringFlow] progression failed
                  completedScriptPointID: \(scheduledPointID)
                  nextScriptPointID: \(nextScriptPointID)
                  error: \(error.localizedDescription)
                """)
                return .failed(
                    "\(scheduledPointID) completed, but \(nextScriptPointID) could not be loaded: \(error.localizedDescription)"
                )
            }

            if progression.automaticAdvance {
                guard nextDescriptor.trigger.kind ==
                        .priorScriptPointCompleted else {
                    return .failed(
                        "\(scheduledPointID) requests automatic advance, but \(nextScriptPointID) is not triggered by priorScriptPointCompleted."
                    )
                }

                if let completedIdentity =
                    result.identity {
                    TuringFlowLog.event(
                        "next point scheduled",
                        identity:
                            completedIdentity,
                        fields: [
                            (
                                "nextScriptPointID",
                                nextScriptPointID
                            ),
                            (
                                "nextTrigger",
                                nextDescriptor.trigger
                                    .kind.rawValue
                            ),
                            (
                                "delaySeconds",
                                String(
                                    format: "%.3f",
                                    nextDescriptor.trigger
                                        .delaySeconds
                                )
                            )
                        ]
                    )
                } else {
                    print("""
                    [TuringFlow] next point scheduled
                      parentScriptPointID: \(descriptor.scriptPointID)
                      nextScriptPointID: \(nextScriptPointID)
                      nextTrigger: \(nextDescriptor.trigger.kind.rawValue)
                      delaySeconds: \(String(format: "%.3f", nextDescriptor.trigger.delaySeconds))
                    """)
                }

                scheduledPointID =
                    nextScriptPointID
                scheduledTrigger =
                    .priorScriptPointCompleted(
                        parentScriptPointID:
                            descriptor
                                .scriptPointID
                    )
                continue
            }

            if nextDescriptor.trigger.kind ==
                .priorConversationPlaybackCompleted {
                pendingConversationAdvance =
                    PendingConversationAdvance(
                        parentScriptPointID:
                            descriptor
                                .scriptPointID,
                        nextScriptPointID:
                            nextScriptPointID,
                        conversationKey:
                            descriptor
                                .transmission
                                .conversationKey
                    )

                print("""
                [TuringFlow] next point waiting for conversation
                  parentScriptPointID: \(descriptor.scriptPointID)
                  nextScriptPointID: \(nextScriptPointID)
                  conversationKey: \(descriptor.transmission.conversationKey)
                  microphoneGate: \(descriptor.progression.interactionGateAfterCompletion.rawValue)
                """)
            } else {
                pendingConversationAdvance = nil
            }

            return result.voiceRunResult
        }
    }

    func startFromContinuation(
        scriptPointID: String,
        checkpoint: TuringPrologueCheckpoint
    ) async -> TuringVoiceRunResult {
        let allowed: Bool
        switch (checkpoint, scriptPointID) {
        case (.notStarted, "prologue.scriptPoint01"),
             (.script01ConversationVoiceCompleted, "prologue.scriptPoint02"),
             (.script02PromptVoiceCompleted, "prologue.scriptPoint03"):
            allowed = true
        default:
            allowed = false
        }

        guard allowed else {
            return .failed(
                "Invalid continuation point \(scriptPointID) for \(checkpoint)."
            )
        }
        return await start(
            scriptPointID: scriptPointID,
            trigger: .continuationRestore(checkpoint: checkpoint),
            allowExplicitReplay: true
        )
    }

    func pendingConversationAdvanceContext(
        for conversationKey: String
    ) -> TuringPendingConversationAdvanceContext? {
        guard let pending = pendingConversationAdvance,
              pending.conversationKey == conversationKey else {
            return nil
        }
        return TuringPendingConversationAdvanceContext(
            parentScriptPointID: pending.parentScriptPointID,
            nextScriptPointID: pending.nextScriptPointID,
            conversationKey: pending.conversationKey
        )
    }

    func notifyConversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        try await completionEventSink?.conversationPlaybackCompleted(event)
    }

    func conversationPlaybackCompleted(
        conversationKey: String,
        interactionLease: StoryInteractionLease? = nil
    ) async -> TuringVoiceRunResult? {
        guard let pending =
                pendingConversationAdvance else {
            return nil
        }

        guard pending.conversationKey ==
                conversationKey else {
            print("""
            [TuringFlow] conversation completion ignored
              expectedConversationKey: \(pending.conversationKey)
              receivedConversationKey: \(conversationKey)
            """)
            return nil
        }

        pendingConversationAdvance = nil

        if let interactionLease {
            do {
                try await adoptConversationInteractionLease(
                    interactionLease
                )
            } catch {
                return .failed(
                    "Device operation failed: \(error.localizedDescription)"
                )
            }
        }

        await TuringFlowInteractionGateController
            .shared
            .closeForScheduledProgression(
                reason:
                    "conversationPlaybackCompleted.\(pending.parentScriptPointID)"
            )

        return await start(
            scriptPointID:
                pending.nextScriptPointID,
            trigger:
                .priorConversationPlaybackCompleted(
                    parentScriptPointID:
                        pending
                            .parentScriptPointID
                )
        )
    }

    func adoptConversationInteractionLease(
        _ lease: StoryInteractionLease
    ) async throws {
        guard activeSequenceID == nil,
              activeInteractionLease == nil else {
            throw StoryInteractionClaimError.exclusiveOwnerActive
        }
        try await interactionArbiter.requireCurrent(lease)
        guard case .turingFlow = lease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        activeInteractionLease = lease
    }

    func transferActiveInteractionToBattle(
        battleInstanceID: UUID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard let activeInteractionLease else {
            throw StoryInteractionClaimError.staleLease
        }
        let battleLease = try await interactionArbiter
            .transferTuringToBattle(
                turingLease: activeInteractionLease,
                battleInstanceID: battleInstanceID,
                reason: reason
            )
        self.activeInteractionLease = nil
        return battleLease
    }

    private func finishInteractionLease(reason: String) async {
        guard let activeInteractionLease else { return }
        self.activeInteractionLease = nil
        await interactionArbiter.release(
            activeInteractionLease,
            reason: reason
        )
    }

    func resetEpisode(reason: String) async {
        if let activeInteractionLease {
            self.activeInteractionLease = nil
            await interactionArbiter.release(
                activeInteractionLease,
                reason: "episodeReset.\(reason)"
            )
        }
        activeSequenceID = nil
        completedScriptPointIDs.removeAll(
            keepingCapacity: false
        )
        pendingConversationAdvance = nil
        catalogValidated = false

        await seedStore.clearAll(
            reason:
                "episodeFlowReset.\(reason)"
        )
        await TuringFlowInteractionGateController
            .shared
            .reset(reason: reason)

        print("""
        [TuringFlow] episode progression reset
          reason: \(reason)
        """)
    }

    func quiesceForStoryTeleport(reason: String) async {
        if let activeInteractionLease {
            self.activeInteractionLease = nil
            await interactionArbiter.release(
                activeInteractionLease,
                reason: "storyTeleport.\(reason)"
            )
        }
        activeSequenceID = nil
        pendingConversationAdvance = nil
        print("[TuringFlow] quiesced for Story teleport reason=\(reason)")
    }

    func restore(
        completedScriptPointIDs: Set<String>,
        pendingConversationAdvance: RestoredPendingConversationAdvance?
    ) async {
        guard activeSequenceID == nil else {
            assertionFailure("Cannot restore while a Turing Flow sequence is active.")
            return
        }
        self.completedScriptPointIDs = completedScriptPointIDs
        if let pendingConversationAdvance {
            self.pendingConversationAdvance = PendingConversationAdvance(
                parentScriptPointID: pendingConversationAdvance.parentScriptPointID,
                nextScriptPointID: pendingConversationAdvance.nextScriptPointID,
                conversationKey: pendingConversationAdvance.conversationKey
            )
        } else {
            self.pendingConversationAdvance = nil
        }
        await seedStore.clearAll(reason: "storyTeleportRestore")
        print("""
        [TuringContinuation] episode flow restored
          completedScriptPointIDs: \(completedScriptPointIDs.sorted())
          pendingConversationParent: \(pendingConversationAdvance?.parentScriptPointID ?? "none")
          pendingConversationNext: \(pendingConversationAdvance?.nextScriptPointID ?? "none")
        """)
    }

    func markCompletedForCompatibility(
        _ scriptPointIDs: [String]
    ) {
        completedScriptPointIDs.formUnion(
            scriptPointIDs
        )
    }

    private func publishCompletion(
        result: TuringFlowResult,
        scriptPointID: String,
        triggerSource: TuringFlowTriggerSource
    ) async throws {
        guard let identity = result.identity else {
            print("[TuringFlow] completion event omitted: successful result had no identity scriptPointID=\(scriptPointID)")
            throw TuringStoryContinuationError.noValidSnapshot
        }
        let event = TuringScriptPointCompletionEvent(
            eventID: UUID(),
            scriptPointID: scriptPointID,
            flowInstanceID: identity.flowInstanceID,
            triggerSource: triggerSource
        )
        try await completionEventSink?.scriptPointCompleted(event)
        print("""
        [TuringFlow] actual script point completion published
          scriptPointID: \(scriptPointID)
          flowInstanceID: \(identity.flowInstanceID.uuidString)
          trigger: \(triggerSource.logValue)
        """)
    }
}

struct TuringPendingConversationAdvanceContext: Sendable, Equatable {
    let parentScriptPointID: String
    let nextScriptPointID: String
    let conversationKey: String
}
