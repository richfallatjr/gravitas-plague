import CryptoKit
import Foundation

nonisolated struct TuringLiveConversationResourceProof: Sendable, Equatable {
    let resourcePath: String
    let byteCount: Int
    let sha256: String
}

nonisolated struct TuringConversationImmediateDeviceContext:
    Sendable,
    Equatable
{
    let momentID: String
    let scriptPointID: String
    let prerecordingID: String
    let speakerCharacterID: TuringConversationCharacterID
    let transcript: String
    let transcriptProof: TuringLiveConversationResourceProof
}

nonisolated struct TuringConversationTargetCharacterContext:
    Sendable,
    Equatable
{
    let targetCharacterID: TuringConversationCharacterID
    let selectedMomentID: String
    let selectionPosition: TuringConversationTargetContextPosition
    let voicePromptID: String
    let voicePromptProof: TuringLiveConversationResourceProof
    let characterProfileID: String
    let listenerProfileID: String
    let voiceID: String
    let conversationKey: String
    let outputRoute: TuringVoiceOutputContext
    let promptVariant: TuringConversationPromptVariant
    let promptVoiceStoryContext: String
    let priorTargetTranscript: String?
}

nonisolated struct TuringLiveConversationSeed: Sendable, Equatable {
    let seedID: UUID
    let episodeID: TuringEpisodeID
    let segmentID: String
    let sourceMomentID: String
    let microphoneGeneration: UInt64
    let parentFlowSequenceID: UUID
    let parentFlowInstanceID: UUID
    let parentPlaybackRunID: String
    let scriptPointID: String
    let authoredMediaItemID: String
    let authoredMediaRole: TuringAuthoredMediaItem.Role
    let interactionSurface: StoryInteractionSurfaceID
    let immediateDeviceContext: TuringConversationImmediateDeviceContext
    let targetContext: TuringConversationTargetCharacterContext
    let backgroundMusic: TuringFlowBackgroundMusicDescriptor?
    let catalogRetention: TuringLiveConversationCatalog.Entry.Retention

    var prerecordingID: String { immediateDeviceContext.prerecordingID }
    var prerecordingTranscript: String { immediateDeviceContext.transcript }
    var prerecordingProof: TuringLiveConversationResourceProof {
        immediateDeviceContext.transcriptProof
    }
    var voicePromptID: String { targetContext.voicePromptID }
    var voicePromptProof: TuringLiveConversationResourceProof {
        targetContext.voicePromptProof
    }
    var characterID: String { targetContext.targetCharacterID.rawValue }
    var characterProfileID: String { targetContext.characterProfileID }
    var listenerProfileID: String { targetContext.listenerProfileID }
    var voiceID: String { targetContext.voiceID }
    var outputRoute: TuringVoiceOutputContext { targetContext.outputRoute }
    var conversationKey: String { targetContext.conversationKey }
    var promptVariant: TuringConversationPromptVariant {
        targetContext.promptVariant
    }
    var promptVoiceStoryContext: String {
        targetContext.promptVoiceStoryContext
    }

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

    func withMicrophoneGeneration(
        _ value: UInt64
    ) -> TuringLiveConversationSeed {
        TuringLiveConversationSeed(
            seedID: seedID,
            episodeID: episodeID,
            segmentID: segmentID,
            sourceMomentID: sourceMomentID,
            microphoneGeneration: value,
            parentFlowSequenceID: parentFlowSequenceID,
            parentFlowInstanceID: parentFlowInstanceID,
            parentPlaybackRunID: parentPlaybackRunID,
            scriptPointID: scriptPointID,
            authoredMediaItemID: authoredMediaItemID,
            authoredMediaRole: authoredMediaRole,
            interactionSurface: interactionSurface,
            immediateDeviceContext: immediateDeviceContext,
            targetContext: targetContext,
            backgroundMusic: backgroundMusic,
            catalogRetention: catalogRetention
        )
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
        microphoneGeneration: UInt64,
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

        let catalogStore = try TuringLiveConversationCatalogStore(bundle: bundle)
        guard let episode = catalogStore.episode(containing: entry) else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation moment \(entry.momentID) has no episode."
            )
        }
        guard descriptor.transmission.characterID ==
                entry.speakerCharacterID.rawValue,
              TuringConversationSurfacePolicy.validates(
                  target: entry.conversationTargetCharacterID,
                  for: entry.interactionSurface
              ) else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation speaker or target policy is invalid for \(entry.momentID)."
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
        guard prerecording.speaker == entry.speakerCharacterID.rawValue else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation PR speaker does not match \(entry.momentID)."
            )
        }

        let selection = try TuringConversationTargetContextResolver(
            catalog: catalogStore.routingCatalog
        ).resolve(
            episodeID: episode.episodeID,
            currentMoment: entry
        )
        let selectedMoment = selection.selectedMoment
        let targetDescriptor = try TuringFlowDescriptorStore().require(
            selectedMoment.scriptPointID
        )
        let voicePromptID = try resolveVoicePromptID(
            entry: selectedMoment,
            descriptor: targetDescriptor
        )
        let voicePrompt = try voicePromptStore.descriptor(id: voicePromptID)
        guard voicePrompt.conversationKey ==
                targetDescriptor.transmission.conversationKey,
              voicePrompt.outputContext ==
                targetDescriptor.transmission.outputRoute,
              voicePrompt.speakerID == selection.targetCharacterID.rawValue else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation target VoicePrompt does not match \(entry.momentID)."
            )
        }

        let prerecordingPath = "Turing/Prerecordings/\(item.id).json"
        let voicePromptPath = "Turing/VoicePrompts/\(voicePromptID).json"
        let priorTargetTranscript: String?
        if selection.position == .currentOrPrior {
            priorTargetTranscript = try prerecordingStore.descriptor(
                id: selectedMoment.authoredPrerecordingID
            ).transcript
        } else {
            priorTargetTranscript = nil
        }
        let context = TuringPromptVoiceStoryContextBuilder.standard(voicePrompt)
        return TuringLiveConversationSeed(
            seedID: UUID(),
            episodeID: episode.episodeID,
            segmentID: entry.segmentID,
            sourceMomentID: entry.momentID,
            microphoneGeneration: microphoneGeneration,
            parentFlowSequenceID: parentSequenceID,
            parentFlowInstanceID: identity.flowInstanceID,
            parentPlaybackRunID: identity.playbackRunID,
            scriptPointID: descriptor.scriptPointID,
            authoredMediaItemID: item.id,
            authoredMediaRole: item.role,
            interactionSurface: entry.interactionSurface,
            immediateDeviceContext: TuringConversationImmediateDeviceContext(
                momentID: entry.momentID,
                scriptPointID: entry.scriptPointID,
                prerecordingID: prerecording.prerecordingID,
                speakerCharacterID: entry.speakerCharacterID,
                transcript: prerecording.transcript,
                transcriptProof: try proof(prerecordingPath, bundle: bundle)
            ),
            targetContext: TuringConversationTargetCharacterContext(
                targetCharacterID: selection.targetCharacterID,
                selectedMomentID: selectedMoment.momentID,
                selectionPosition: selection.position,
                voicePromptID: voicePrompt.voicePromptID,
                voicePromptProof: try proof(voicePromptPath, bundle: bundle),
                characterProfileID: voicePrompt.characterProfileID,
                listenerProfileID: voicePrompt.listenerProfileID,
                voiceID: voicePrompt.voiceID,
                conversationKey: voicePrompt.conversationKey,
                outputRoute: voicePrompt.outputContext,
                promptVariant: .resolved(
                    scriptPointID: selectedMoment.scriptPointID,
                    promptTemplateID: voicePrompt.effectivePromptTemplateID
                ),
                promptVoiceStoryContext: context.storyContext,
                priorTargetTranscript: priorTargetTranscript
            ),
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
