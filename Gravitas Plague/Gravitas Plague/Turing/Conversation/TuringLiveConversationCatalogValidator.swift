import Foundation

struct TuringLiveConversationCatalogValidator: Sendable {
    private let catalogStore: TuringLiveConversationCatalogStore
    private let descriptorStore = TuringFlowDescriptorStore()
    private let prerecordingStore = TuringPrerecordingStore()
    private let voicePromptStore = TuringVoicePromptTriggerStore()
    private let characterRuntimeStore = TuringCharacterRuntimeStore()
    private let characterProfileStore = TuringCharacterProfileStore()

    init(bundle: Bundle = .main) throws {
        catalogStore = try TuringLiveConversationCatalogStore(bundle: bundle)
    }

    func validate() throws {
        for entry in catalogStore.entries {
            let descriptor = try descriptorStore.require(entry.scriptPointID)
            guard descriptor.transmission.effectiveInteractionSurface ==
                    entry.interactionSurface else {
                throw TuringRuntimeError.invalidConfig(
                    "Live conversation surface mismatch for \(entry.scriptPointID)."
                )
            }
            let prerecording = try prerecordingStore.descriptor(
                id: entry.authoredPrerecordingID
            )
            let authoredPrerecordingIDs =
                [descriptor.transmission.prerecordingID] +
                (descriptor.transmission.generationPipeline?.stages.compactMap {
                    $0.authoredPrerecordingAfterStageID
                } ?? [])
            guard authoredPrerecordingIDs.contains(entry.authoredPrerecordingID) else {
                throw TuringRuntimeError.invalidConfig(
                    "Live conversation PR \(entry.authoredPrerecordingID) is not in the authored media plan for \(entry.scriptPointID)."
                )
            }
            guard prerecording.transcriptMode == .manual,
                  prerecording.transcript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty == false,
                  prerecording.transcript.contains(
                    "REVIEWED_VERBATIM_TRANSCRIPT_REQUIRED"
                  ) == false else {
                throw TuringRuntimeError.invalidConfig(
                    "Live conversation PR \(entry.authoredPrerecordingID) requires an authored transcript."
                )
            }
            _ = try prerecordingStore.audioURL(for: prerecording)

            let voicePromptID: String
            switch entry.voicePromptSource.kind {
            case .transmission:
                guard let id = descriptor.transmission.voicePromptID else {
                    throw TuringRuntimeError.invalidConfig(
                        "Live conversation transmission VoicePrompt is missing for \(entry.scriptPointID)."
                    )
                }
                voicePromptID = id
            case .explicit:
                guard let id = entry.voicePromptSource.voicePromptID else {
                    throw TuringRuntimeError.invalidConfig(
                        "Explicit live conversation VoicePrompt is missing for \(entry.scriptPointID)."
                    )
                }
                voicePromptID = id
            case .generationPipelineStage:
                guard let stageID = entry.voicePromptSource.stageID else {
                    throw TuringRuntimeError.invalidConfig(
                        "Live conversation pipeline VoicePrompt is missing for \(entry.scriptPointID)."
                    )
                }
                let matchingStages =
                    descriptor.transmission.generationPipeline?.stages.filter {
                        $0.stageID == stageID && $0.kind == .voicePrompt
                    } ?? []
                guard matchingStages.count == 1,
                      let id = matchingStages[0].voicePromptID else {
                    throw TuringRuntimeError.invalidConfig(
                        "Live conversation pipeline VoicePrompt must resolve exactly once for \(entry.scriptPointID)."
                    )
                }
                voicePromptID = id
            }
            let prompt = try voicePromptStore.descriptor(id: voicePromptID)
            let runtime = try characterRuntimeStore.require(
                descriptor.transmission.characterID
            )
            let characterProfile = try characterProfileStore.profile(
                id: prompt.characterProfileID
            )
            _ = try characterProfileStore.profile(id: prompt.listenerProfileID)
            let storyContext =
                TuringPromptVoiceStoryContextBuilder.standard(prompt).storyContext
            guard prompt.speakerID == descriptor.transmission.characterID,
                  prompt.voiceID == runtime.voiceID,
                  prerecording.speaker == runtime.characterID,
                  prerecording.voiceID == runtime.voiceID,
                  characterProfile.characterID == runtime.characterID,
                  prompt.conversationKey == descriptor.transmission.conversationKey,
                  prompt.outputContext == descriptor.transmission.outputRoute,
                  runtime.supports(descriptor.transmission.outputRoute),
                  storyContext.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty == false else {
                throw TuringRuntimeError.invalidConfig(
                    "Live conversation VoicePrompt identity mismatch for \(entry.scriptPointID)."
                )
            }
        }
        print("[TuringLiveConversation] catalog validated entries=\(catalogStore.entries.count)")
    }
}
