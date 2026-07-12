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
            let prompt =
                try promptStore.descriptor(
                    id:
                        descriptor.transmission
                            .voicePromptID
                )
            let character =
                try characterStore.require(
                    descriptor.transmission
                        .characterID
                )

            try validateIdentity(
                descriptor: descriptor,
                prerecording:
                    prerecording,
                prompt: prompt,
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
            TuringVoicePromptTriggerDescriptor,
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
              prompt.speakerID ==
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
                    .conversationKey,
              character.supports(
                descriptor.transmission
                    .outputRoute
              ) else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow identity mismatch at \(descriptor.scriptPointID)."
            )
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
