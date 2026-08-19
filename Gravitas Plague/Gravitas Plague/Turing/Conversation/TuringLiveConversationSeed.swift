import CryptoKit
import Foundation

nonisolated struct TuringLiveConversationResourceProof: Sendable, Equatable {
    let resourcePath: String
    let byteCount: Int
    let sha256: String
}

nonisolated struct TuringLiveConversationSeed: Sendable, Equatable {
    let seedID: UUID
    let parentFlowSequenceID: UUID
    let parentFlowInstanceID: UUID
    let parentPlaybackRunID: String
    let scriptPointID: String
    let authoredMediaItemID: String
    let authoredMediaRole: TuringAuthoredMediaItem.Role
    let prerecordingID: String
    let prerecordingTranscript: String
    let prerecordingProof: TuringLiveConversationResourceProof
    let voicePromptID: String
    let voicePromptProof: TuringLiveConversationResourceProof
    let characterID: String
    let characterProfileID: String
    let listenerProfileID: String
    let voiceID: String
    let interactionSurface: StoryInteractionSurfaceID
    let outputRoute: TuringVoiceOutputContext
    let conversationKey: String
    let promptVariant: TuringConversationPromptVariant
    let promptVoiceStoryContext: String
    let backgroundMusic: TuringFlowBackgroundMusicDescriptor?
    let catalogRetention: TuringLiveConversationCatalog.Entry.Retention

    var authoredIdentity: TuringFlowIdentity {
        TuringFlowIdentity(
            flowInstanceID: parentFlowInstanceID,
            scriptPointID: scriptPointID,
            characterID: characterID,
            prerecordingID: prerecordingID,
            voicePromptID: voicePromptID,
            interactionSurface: interactionSurface,
            playbackRunID: parentPlaybackRunID
        )
    }

    func isEligible(
        forHostSequenceID hostSequenceID: UUID,
        hostFlowInstanceID: UUID
    ) -> Bool {
        switch catalogRetention {
        case .currentAuthoredItem:
            return parentFlowSequenceID == hostSequenceID &&
                parentFlowInstanceID == hostFlowInstanceID
        case .currentFlowSequence:
            return parentFlowSequenceID == hostSequenceID
        case .untilExplicitInvalidation:
            return true
        }
    }
}

struct TuringLiveConversationSeedResolver: Sendable {
    private let prerecordingStore = TuringPrerecordingStore()
    private let voicePromptStore = TuringVoicePromptTriggerStore()

    func resolve(
        entry: TuringLiveConversationCatalog.Entry,
        item: TuringAuthoredMediaItem,
        descriptor: TuringFlowDescriptor,
        parentSequenceID: UUID,
        identity: TuringFlowIdentity,
        bundle: Bundle = .main
    ) throws -> TuringLiveConversationSeed {
        guard item.role == .primaryPrerecording || item.role == .authoredBridge,
              item.id == entry.authoredPrerecordingID,
              descriptor.scriptPointID == entry.scriptPointID,
              descriptor.transmission.effectiveInteractionSurface == entry.interactionSurface else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation authored-media identity does not match its catalog entry."
            )
        }

        let prerecording = try prerecordingStore.descriptor(id: item.id)
        guard prerecording.transcriptMode == .manual,
              prerecording.transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation PR \(item.id) requires a manual transcript."
            )
        }
        let voicePromptID = try resolveVoicePromptID(
            entry: entry,
            descriptor: descriptor
        )
        let voicePrompt = try voicePromptStore.descriptor(id: voicePromptID)
        guard voicePrompt.conversationKey == descriptor.transmission.conversationKey,
              voicePrompt.outputContext == descriptor.transmission.outputRoute,
              voicePrompt.speakerID == descriptor.transmission.characterID else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation VoicePrompt does not match \(descriptor.scriptPointID)."
            )
        }

        let prerecordingPath = "Turing/Prerecordings/\(item.id).json"
        let voicePromptPath = "Turing/VoicePrompts/\(voicePromptID).json"
        let context = TuringPromptVoiceStoryContextBuilder.standard(voicePrompt)
        return TuringLiveConversationSeed(
            seedID: UUID(),
            parentFlowSequenceID: parentSequenceID,
            parentFlowInstanceID: identity.flowInstanceID,
            parentPlaybackRunID: identity.playbackRunID,
            scriptPointID: descriptor.scriptPointID,
            authoredMediaItemID: item.id,
            authoredMediaRole: item.role,
            prerecordingID: prerecording.prerecordingID,
            prerecordingTranscript: prerecording.transcript,
            prerecordingProof: try proof(prerecordingPath, bundle: bundle),
            voicePromptID: voicePrompt.voicePromptID,
            voicePromptProof: try proof(voicePromptPath, bundle: bundle),
            characterID: descriptor.transmission.characterID,
            characterProfileID: voicePrompt.characterProfileID,
            listenerProfileID: voicePrompt.listenerProfileID,
            voiceID: voicePrompt.voiceID,
            interactionSurface: entry.interactionSurface,
            outputRoute: descriptor.transmission.outputRoute,
            conversationKey: descriptor.transmission.conversationKey,
            promptVariant: .resolved(
                scriptPointID: descriptor.scriptPointID,
                promptTemplateID: voicePrompt.effectivePromptTemplateID
            ),
            promptVoiceStoryContext: context.storyContext,
            backgroundMusic: descriptor.transmission.backgroundMusic,
            catalogRetention: entry.retention
        )
    }

    func proofsStillMatch(
        _ seed: TuringLiveConversationSeed,
        bundle: Bundle = .main
    ) -> Bool {
        (try? proof(seed.prerecordingProof.resourcePath, bundle: bundle)) ==
            seed.prerecordingProof &&
        (try? proof(seed.voicePromptProof.resourcePath, bundle: bundle)) ==
            seed.voicePromptProof
    }

    private func resolveVoicePromptID(
        entry: TuringLiveConversationCatalog.Entry,
        descriptor: TuringFlowDescriptor
    ) throws -> String {
        switch entry.voicePromptSource.kind {
        case .transmission:
            guard let id = descriptor.transmission.voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "Live conversation transmission has no VoicePrompt."
                )
            }
            return id
        case .explicit:
            guard let id = entry.voicePromptSource.voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "Explicit live conversation VoicePrompt ID is missing."
                )
            }
            return id
        case .generationPipelineStage:
            guard let stageID = entry.voicePromptSource.stageID,
                  let stage = descriptor.transmission.generationPipeline?.stages.first(
                    where: { $0.stageID == stageID && $0.kind == .voicePrompt }
                  ),
                  let id = stage.voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "Live conversation VoicePrompt pipeline stage is missing."
                )
            }
            return id
        }
    }

    private func proof(
        _ resourcePath: String,
        bundle: Bundle
    ) throws -> TuringLiveConversationResourceProof {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: resourcePath,
            bundle: bundle
        )
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return TuringLiveConversationResourceProof(
            resourcePath: resourcePath,
            byteCount: data.count,
            sha256: digest
        )
    }
}

nonisolated struct TuringLiveConversationSeedRegistrySnapshot: Sendable, Equatable {
    let seedsBySurface: [StoryInteractionSurfaceID: TuringLiveConversationSeed]
}

actor TuringLiveConversationSeedRegistry {
    static let shared = TuringLiveConversationSeedRegistry()

    private var seedsBySurface:
        [StoryInteractionSurfaceID: TuringLiveConversationSeed] = [:]

    func authoredItemStarted(seed: TuringLiveConversationSeed) {
        seedsBySurface[seed.interactionSurface] = seed
    }

    func authoredItemCompleted(seedID: UUID) {
        let expiredSurfaces = seedsBySurface.compactMap { surface, seed in
            seed.seedID == seedID && seed.catalogRetention == .currentAuthoredItem
                ? surface
                : nil
        }
        for surface in expiredSurfaces {
            seedsBySurface.removeValue(forKey: surface)
        }
    }

    func restoreForOptionalFailureRetry(
        seed: TuringLiveConversationSeed
    ) {
        seedsBySurface[seed.interactionSurface] = seed
        print(
            "[TuringLiveConversation] seed restored for retry " +
                "surface=\(seed.interactionSurface.rawValue) " +
                "seedID=\(seed.seedID.uuidString)"
        )
    }

    func flowSequenceCompleted(sequenceID: UUID) {
        seedsBySurface = seedsBySurface.filter { _, seed in
            seed.parentFlowSequenceID != sequenceID ||
                seed.catalogRetention == .untilExplicitInvalidation
        }
    }

    func invalidate(surface: StoryInteractionSurfaceID, reason: String) {
        seedsBySurface.removeValue(forKey: surface)
        print("[TuringLiveConversation] seed invalidated surface=\(surface.rawValue) reason=\(reason)")
    }

    func snapshot(
        allowedSurfaces: Set<StoryInteractionSurfaceID>,
        hostSequenceID: UUID,
        hostFlowInstanceID: UUID
    ) -> TuringLiveConversationSeedRegistrySnapshot {
        .init(
            seedsBySurface: seedsBySurface.filter {
                allowedSurfaces.contains($0.key) &&
                    $0.value.isEligible(
                        forHostSequenceID: hostSequenceID,
                        hostFlowInstanceID: hostFlowInstanceID
                    )
            }
        )
    }

    func recaptureForSelection(
        surface: StoryInteractionSurfaceID,
        expectedSeedID: UUID,
        hostSequenceID: UUID,
        hostFlowInstanceID: UUID
    ) throws -> TuringLiveConversationSeed {
        guard let seed = seedsBySurface[surface],
              seed.seedID == expectedSeedID,
              seed.isEligible(
                forHostSequenceID: hostSequenceID,
                hostFlowInstanceID: hostFlowInstanceID
              ),
              TuringLiveConversationSeedResolver().proofsStillMatch(seed) else {
            throw TuringRuntimeError.invalidConfig(
                "The selected live conversation seed is stale."
            )
        }
        return seed
    }

    func hasAvailableSeed(
        surface: StoryInteractionSurfaceID
    ) -> Bool {
        seedsBySurface[surface] != nil
    }

    func clearAll(reason: String) {
        seedsBySurface.removeAll(keepingCapacity: false)
        print("[TuringLiveConversation] all seeds cleared reason=\(reason)")
    }
}
