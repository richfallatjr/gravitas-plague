import Foundation

private struct TuringFlowCatalogResource:
    Codable,
    Sendable
{
    let schemaVersion: Int
    let scriptPointIDs: [String]
}

protocol TuringFlowCatalogValidating: Sendable {
    func validate() async throws
}

struct TuringFlowCatalogValidator:
    TuringFlowCatalogValidating,
    Sendable
{
    private let descriptorStore:
        any TuringFlowDescriptorLoading
    private let prerecordingStore:
        any TuringPrerecordingLoading
    private let promptStore:
        any TuringVoicePromptTriggerLoading
    private let characterStore:
        any TuringCharacterRuntimeProviding
    private let routeResolver:
        any TuringFlowRouteResolving

    init(
        descriptorStore:
            any TuringFlowDescriptorLoading =
                TuringFlowDescriptorStore(),
        prerecordingStore:
            any TuringPrerecordingLoading =
                TuringPrerecordingStore(),
        promptStore:
            any TuringVoicePromptTriggerLoading =
                TuringVoicePromptTriggerStore(),
        characterStore:
            any TuringCharacterRuntimeProviding =
                TuringCharacterRuntimeStore(),
        routeResolver:
            any TuringFlowRouteResolving =
                TuringDefaultFlowRouteResolver()
    ) {
        self.descriptorStore = descriptorStore
        self.prerecordingStore = prerecordingStore
        self.promptStore = promptStore
        self.characterStore = characterStore
        self.routeResolver = routeResolver
    }

    func validate() async throws {
        let catalog =
            try TuringResourceLoader.decodeResource(
                TuringFlowCatalogResource.self,
                resourcePath:
                    "Turing/ScriptPoints/catalog.json"
            )

        guard catalog.schemaVersion == 1 else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow catalog schemaVersion must be 1."
            )
        }

        let unique =
            Set(catalog.scriptPointIDs)

        guard unique.count ==
                catalog.scriptPointIDs.count,
              unique.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow catalog contains duplicate IDs or is empty."
            )
        }

        var descriptors:
            [String: TuringFlowDescriptor] = [:]

        for id in catalog.scriptPointIDs {
            descriptors[id] =
                try descriptorStore.require(id)
        }

        for id in catalog.scriptPointIDs {
            guard let descriptor =
                    descriptors[id] else {
                continue
            }

            let prerecording =
                try prerecordingStore.descriptor(
                    id:
                        descriptor.transmission
                            .prerecordingID
                )
            _ = try prerecordingStore.audioURL(
                for: prerecording
            )
            let character =
                try characterStore.require(
                    descriptor.transmission
                        .characterID
                )
            let prompt:
                TuringVoicePromptTriggerDescriptor?
            if let voicePromptID =
                descriptor.transmission.voicePromptID {
                prompt =
                    try promptStore.descriptor(
                        id: voicePromptID
                    )
                if let prompt {
                    _ = try TuringResourceLoader.resourceURL(
                        resourcePath:
                            prompt.effectivePromptTemplateID
                                .resourcePath
                    )
                    _ = try TuringResourceLoader.resourceURL(
                        resourcePath:
                            prompt.effectivePromptTemplateID
                                .conversationVariant
                                .resourcePath
                    )
                }
            } else {
                prompt = nil
            }

            if let music =
                descriptor.transmission.backgroundMusic {
                _ = try TuringResourceLoader.resourceURL(
                    resourcePath: music.resourcePath
                )
            }

            try validateIdentity(
                descriptor: descriptor,
                prerecording:
                    prerecording,
                prompt: prompt,
                character: character
            )
            try validateGenerationPipelineIfNeeded(
                descriptor: descriptor,
                character: character
            )

            let route =
                try await routeResolver.require(
                    descriptor.transmission
                        .outputRoute
                )
            try await route.validate(
                descriptor: descriptor,
                character: character
            )

            if let next =
                descriptor.progression
                    .nextScriptPointID {
                guard let nextDescriptor =
                        descriptors[next] else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(id) references missing nextScriptPointID \(next)."
                    )
                }

                if descriptor.progression
                    .automaticAdvance {
                    guard nextDescriptor.trigger
                        .kind ==
                        .priorScriptPointCompleted else {
                        throw TuringRuntimeError.invalidConfig(
                            "\(id) auto-advances to \(next), but the next trigger is \(nextDescriptor.trigger.kind.rawValue)."
                        )
                    }
                } else if nextDescriptor.trigger
                    .kind ==
                    .priorScriptPointCompleted {
                    throw TuringRuntimeError.invalidConfig(
                        "\(id) does not auto-advance, but \(next) requires priorScriptPointCompleted."
                    )
                }

                guard descriptor.transmission
                    .conversationKey ==
                    nextDescriptor.transmission
                        .conversationKey else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(id) and \(next) change conversationKey across one progression edge."
                    )
                }
            }
        }

        try rejectAutomaticCycles(
            descriptors: descriptors
        )

        print("""
        [TuringFlow] catalog validated
          scriptPointCount: \(catalog.scriptPointIDs.count)
          scriptPointIDs: \(catalog.scriptPointIDs)
        """)
    }

    private func validateIdentity(
        descriptor: TuringFlowDescriptor,
        prerecording:
            TuringPrerecordingDescriptor,
        prompt:
            TuringVoicePromptTriggerDescriptor?,
        character:
            TuringCharacterRuntimeDefinition
    ) throws {
        guard descriptor.transmission
                .characterID ==
                character.characterID,
              prerecording.speaker ==
                character.characterID,
              prerecording.voiceID ==
                character.voiceID,
              character.supports(
                descriptor.transmission
                    .outputRoute
              ) else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow identity mismatch at \(descriptor.scriptPointID)."
            )
        }

        if descriptor.transmission.usesLegacyVoicePrompt {
            guard let prompt else {
                throw TuringRuntimeError.invalidConfig(
                    "Turing Flow prompt is missing at \(descriptor.scriptPointID)."
                )
            }
            let promptProfile =
                try TuringCharacterProfileStore()
                    .profile(
                        id: prompt
                            .characterProfileID
                    )
            guard prompt.speakerID ==
                    character.characterID,
                  prompt.voiceID ==
                    character.voiceID,
                  promptProfile.characterID ==
                    character.characterID,
                  prompt.outputContext ==
                    descriptor.transmission
                        .outputRoute,
                  prompt.conversationKey ==
                    descriptor.transmission
                        .conversationKey else {
                throw TuringRuntimeError.invalidConfig(
                    "Turing Flow prompt identity mismatch at \(descriptor.scriptPointID)."
                )
            }
        }
    }

    private func validateGenerationPipelineIfNeeded(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard let pipeline =
                descriptor.transmission.generationPipeline else {
            return
        }

        guard pipeline.schemaVersion == 1 else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) generationPipeline schemaVersion must be 1."
            )
        }

        guard pipeline.stages.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) generationPipeline must contain at least one stage."
            )
        }

        var seenStageIDs = Set<String>()
        var seenAuthoredBridgeIDs = Set<String>()
        var priorScriptVoiceStageIDs = Set<String>()
        for stage in pipeline.stages {
            let stageID =
                stage.stageID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            guard stageID.isEmpty == false,
                  seenStageIDs.insert(stageID).inserted else {
                throw TuringRuntimeError.invalidConfig(
                    "\(descriptor.scriptPointID) generationPipeline contains duplicate or empty stage IDs."
                )
            }

            if let authoredBridgeID =
                    stage.authoredPrerecordingAfterStageID {
                let trimmedID = authoredBridgeID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard trimmedID.isEmpty == false,
                      seenAuthoredBridgeIDs.insert(trimmedID).inserted else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(descriptor.scriptPointID) generationPipeline contains a duplicate or empty authored bridge ID."
                    )
                }
                let bridge = try prerecordingStore.descriptor(id: trimmedID)
                _ = try prerecordingStore.audioURL(for: bridge)
                guard bridge.speaker == character.characterID,
                      bridge.voiceID == character.voiceID else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(descriptor.scriptPointID) authored bridge \(trimmedID) does not match the stage character."
                    )
                }
            }

            switch stage.kind {
            case .voiceScriptLongform:
                guard let sourcePath =
                        stage.sourceResourcePath,
                      stage.voicePromptID == nil else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(descriptor.scriptPointID) Script Voice stage must provide only sourceResourcePath."
                    )
                }
                let sourceURL =
                    try TuringResourceLoader.resourceURL(
                        resourcePath: sourcePath
                    )
                let source =
                    try String(
                        contentsOf: sourceURL,
                        encoding: .utf8
                    )
                guard source.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(descriptor.scriptPointID) Script Voice source is empty."
                    )
                }
                priorScriptVoiceStageIDs.insert(stageID)

            case .voicePrompt:
                guard let promptID = stage.voicePromptID,
                      stage.sourceResourcePath == nil else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(descriptor.scriptPointID) promptVoice stage must provide only voicePromptID."
                    )
                }
                let prompt =
                    try promptStore.descriptor(id: promptID)
                guard prompt.speakerID ==
                        character.characterID,
                      prompt.voiceID ==
                        character.voiceID,
                      prompt.characterProfileID ==
                        character.characterID,
                      prompt.outputContext ==
                        descriptor.transmission
                            .outputRoute,
                      prompt.conversationKey ==
                        descriptor.transmission
                            .conversationKey else {
                    throw TuringRuntimeError.invalidConfig(
                        "\(descriptor.scriptPointID) pipeline prompt identity mismatch."
                    )
                }

                switch stage.contextSource.kind {
                case .prerecordingTranscript:
                    guard stage.contextSource.stageID == nil else {
                        throw TuringRuntimeError.invalidConfig(
                            "\(descriptor.scriptPointID) prerecording transcript context cannot name a stage."
                        )
                    }

                case .stageSourceTranscript:
                    guard let sourceStageID = stage.contextSource.stageID,
                          priorScriptVoiceStageIDs.contains(sourceStageID) else {
                        throw TuringRuntimeError.invalidConfig(
                            "\(descriptor.scriptPointID) prompt stage \(stageID) must reference an earlier Script Voice source stage."
                        )
                    }
                }
            }
        }
    }

    private func rejectAutomaticCycles(
        descriptors:
            [String: TuringFlowDescriptor]
    ) throws {
        enum Visit: Equatable {
            case visiting
            case complete
        }

        var visits: [String: Visit] = [:]

        func visit(_ id: String) throws {
            if visits[id] == .visiting {
                throw TuringRuntimeError.invalidConfig(
                    "Automatic Turing Flow progression contains a cycle at \(id)."
                )
            }
            if visits[id] == .complete {
                return
            }

            visits[id] = .visiting

            if let descriptor =
                    descriptors[id],
               descriptor.progression
                    .automaticAdvance,
               let next = descriptor
                    .progression
                    .nextScriptPointID {
                try visit(next)
            }

            visits[id] = .complete
        }

        for id in descriptors.keys {
            try visit(id)
        }
    }
}
