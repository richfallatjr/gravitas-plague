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
        let catalog = catalogStore.routingCatalog
        let resolver = TuringConversationTargetContextResolver(catalog: catalog)
        for episode in catalog.episodes {
            try validateEpisodeShape(episode)
            for moment in episode.moments {
                try validateMoment(
                    moment,
                    episode: episode,
                    resolver: resolver
                )
            }
        }
        print(
            "[TuringLiveConversation] routing catalog validated " +
                "episodes=\(catalog.episodes.count) moments=\(catalogStore.entries.count)"
        )
    }

    private func validateEpisodeShape(
        _ episode: TuringLiveConversationCatalog.Episode
    ) throws {
        guard episode.segments.isEmpty == false,
              episode.segments.first(where: {
                  $0.boundaryKind == .chapterStart
              }) != nil else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation episode \(episode.episodeID.rawValue) has no Chapter-start segment."
            )
        }
        let segmentIDs = episode.segments.map(\.segmentID)
        guard Set(segmentIDs).count == segmentIDs.count else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation episode \(episode.episodeID.rawValue) has duplicate segments."
            )
        }
        let momentIDs = episode.moments.map(\.momentID)
        let ordinals = episode.moments.map(\.narrativeOrdinal)
        guard Set(momentIDs).count == momentIDs.count,
              Set(ordinals).count == ordinals.count else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation moment IDs and ordinals must be unique in \(episode.episodeID.rawValue)."
            )
        }
        guard episode.moments.allSatisfy({
            segmentIDs.contains($0.segmentID)
        }) else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation moment references an unknown segment in \(episode.episodeID.rawValue)."
            )
        }
        let checkpointValues = episode.checkpoints.map(\.checkpointRawValue)
        guard Set(checkpointValues).count == checkpointValues.count,
              episode.checkpoints.allSatisfy({
                  segmentIDs.contains($0.segmentID)
              }) else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation checkpoints are invalid in \(episode.episodeID.rawValue)."
            )
        }
    }

    private func validateMoment(
        _ moment: TuringLiveConversationCatalog.Moment,
        episode: TuringLiveConversationCatalog.Episode,
        resolver: TuringConversationTargetContextResolver
    ) throws {
        guard TuringConversationSurfacePolicy.validates(
            target: moment.conversationTargetCharacterID,
            for: moment.interactionSurface
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Conversation target \(moment.conversationTargetCharacterID.rawValue) is not permitted on \(moment.interactionSurface.rawValue)."
            )
        }

        let descriptor = try descriptorStore.require(moment.scriptPointID)
        guard descriptor.transmission.effectiveInteractionSurface ==
                moment.interactionSurface,
              descriptor.transmission.characterID ==
                moment.speakerCharacterID.rawValue else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation speaker or surface mismatch for \(moment.scriptPointID)."
            )
        }
        let prerecording = try prerecordingStore.descriptor(
            id: moment.authoredPrerecordingID
        )
        let authoredPrerecordingIDs =
            [descriptor.transmission.prerecordingID] +
            (descriptor.transmission.generationPipeline?.stages.compactMap {
                $0.authoredPrerecordingAfterStageID
            } ?? [])
        guard authoredPrerecordingIDs.contains(moment.authoredPrerecordingID),
              prerecording.transcriptMode == .manual,
              prerecording.transcript.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false,
              prerecording.speaker == moment.speakerCharacterID.rawValue else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation PR is invalid for \(moment.momentID)."
            )
        }
        _ = try prerecordingStore.audioURL(for: prerecording)

        let selection = try resolver.resolve(
            episodeID: episode.episodeID,
            currentMoment: moment
        )
        let targetMoment = selection.selectedMoment
        let targetDescriptor = try descriptorStore.require(
            targetMoment.scriptPointID
        )
        let voicePromptID = try resolveVoicePromptID(
            moment: targetMoment,
            descriptor: targetDescriptor
        )
        let prompt = try voicePromptStore.descriptor(id: voicePromptID)
        let runtime = try characterRuntimeStore.require(
            selection.targetCharacterID.rawValue
        )
        let characterProfile = try characterProfileStore.profile(
            id: prompt.characterProfileID
        )
        _ = try characterProfileStore.profile(id: prompt.listenerProfileID)
        let storyContext = TuringPromptVoiceStoryContextBuilder.standard(
            prompt
        ).storyContext
        guard prompt.speakerID == selection.targetCharacterID.rawValue,
              prompt.voiceID == runtime.voiceID,
              characterProfile.characterID == runtime.characterID,
              prompt.conversationKey ==
                targetDescriptor.transmission.conversationKey,
              prompt.outputContext == targetDescriptor.transmission.outputRoute,
              runtime.supports(targetDescriptor.transmission.outputRoute),
              storyContext.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Target PromptVoice identity mismatch for \(moment.momentID)."
            )
        }
    }

    private func resolveVoicePromptID(
        moment: TuringLiveConversationCatalog.Moment,
        descriptor: TuringFlowDescriptor
    ) throws -> String {
        switch moment.voicePromptSource.kind {
        case .transmission:
            guard let id = descriptor.transmission.voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "Transmission VoicePrompt is missing for \(moment.momentID)."
                )
            }
            return id
        case .explicit:
            guard let id = moment.voicePromptSource.voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "Explicit VoicePrompt is missing for \(moment.momentID)."
                )
            }
            return id
        case .generationPipelineStage:
            guard let stageID = moment.voicePromptSource.stageID,
                  let stage = descriptor.transmission.generationPipeline?.stages.first(
                      where: { $0.stageID == stageID && $0.kind == .voicePrompt }
                  ),
                  let id = stage.voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "Pipeline VoicePrompt is missing for \(moment.momentID)."
                )
            }
            return id
        }
    }
}
