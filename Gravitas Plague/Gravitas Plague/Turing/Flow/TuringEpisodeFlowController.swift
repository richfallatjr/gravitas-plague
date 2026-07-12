import Foundation

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
    private let historyStore:
        TuringDialogueHistoryStore
    private let catalogValidator:
        (any TuringFlowCatalogValidating)?

    private var activeSequenceID: UUID?
    private var catalogValidated = false
    private var completedScriptPointIDs =
        Set<String>()
    private var pendingConversationAdvance:
        PendingConversationAdvance?

    init(
        engine: TuringFlowEngine = .shared,
        descriptorStore:
            any TuringFlowDescriptorLoading =
                TuringFlowDescriptorStore(),
        seedStore:
            TuringConversationSeedStore = .shared,
        historyStore:
            TuringDialogueHistoryStore = .shared,
        catalogValidator:
            (any TuringFlowCatalogValidating)? =
                TuringFlowCatalogValidator()
    ) {
        self.engine = engine
        self.descriptorStore = descriptorStore
        self.seedStore = seedStore
        self.historyStore = historyStore
        self.catalogValidator = catalogValidator
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

        let sequenceID = UUID()
        activeSequenceID = sequenceID
        defer {
            if activeSequenceID == sequenceID {
                activeSequenceID = nil
            }
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

            completedScriptPointIDs.insert(
                scheduledPointID
            )

            let progression =
                descriptor.progression

            guard let nextScriptPointID =
                    progression.nextScriptPointID else {
                pendingConversationAdvance = nil
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

    func conversationPlaybackCompleted(
        conversationKey: String
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

    func resetEpisode(reason: String) async {
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
        await historyStore.clearAll(
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

    func markCompletedForCompatibility(
        _ scriptPointIDs: [String]
    ) {
        completedScriptPointIDs.formUnion(
            scriptPointIDs
        )
    }
}
