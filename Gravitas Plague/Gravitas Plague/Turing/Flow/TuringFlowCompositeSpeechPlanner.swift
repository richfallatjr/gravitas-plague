import Foundation

struct TuringFlowCompositeSpeechPlan: Sendable {
    let segments: [TuringSpeechSegment]
    let conversationSeed: TuringConversationSeed
    let promptVoiceSeed: TuringPromptVoiceSeed
}

struct TuringFlowCompositeSpeechPlanner: Sendable {
    private let longformRunner: TuringVoiceScriptLongformRunner
    private let voicePromptGenerator: any TuringFlowVoicePromptGenerating
    private let promptStore: any TuringVoicePromptTriggerLoading

    init(
        longformRunner: TuringVoiceScriptLongformRunner = TuringVoiceScriptLongformRunner(),
        voicePromptGenerator: any TuringFlowVoicePromptGenerating,
        promptStore: any TuringVoicePromptTriggerLoading = TuringVoicePromptTriggerStore()
    ) {
        self.longformRunner = longformRunner
        self.voicePromptGenerator = voicePromptGenerator
        self.promptStore = promptStore
    }

    func build(
        descriptor: TuringFlowDescriptor,
        pipeline: TuringFlowGenerationPipelineDescriptor,
        character: TuringCharacterRuntimeDefinition,
        prerecording: TuringPrerecordingDescriptor
    ) async throws -> TuringFlowCompositeSpeechPlan {
        guard pipeline.schemaVersion == 1 else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) generationPipeline schemaVersion must be 1."
            )
        }
        guard pipeline.stages.count == 2,
              pipeline.stages[0].kind == .voiceScriptLongform,
              pipeline.stages[1].kind == .voicePrompt else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) requires voiceScriptLongform followed by voicePrompt."
            )
        }

        let scriptStage = pipeline.stages[0]
        let promptStage = pipeline.stages[1]

        guard let sourceResourcePath = scriptStage.sourceResourcePath,
              scriptStage.voicePromptID == nil else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) Script Voice stage must provide only sourceResourcePath."
            )
        }
        guard let promptID = promptStage.voicePromptID,
              promptStage.sourceResourcePath == nil else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) promptVoice stage must provide only voicePromptID."
            )
        }

        let sourceURL = try TuringResourceLoader.resourceURL(
            resourcePath: sourceResourcePath
        )
        let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) Script Voice source is empty."
            )
        }

        let promptDescriptor = try promptStore.descriptor(id: promptID)
        try Self.validatePromptIdentity(
            promptDescriptor,
            descriptor: descriptor,
            character: character
        )

        async let longformPlan = longformRunner.audiobookPlan(
            request: TuringLongformVoiceScriptRequest(
                requestID: "\(descriptor.scriptPointID).\(scriptStage.stageID)",
                sourceText: sourceText,
                speakerID: character.characterID,
                voiceID: character.voiceID,
                defaultEmotion: scriptStage.defaultEmotion,
                playbackTarget: TuringPlaybackTarget(
                    id: descriptor.transmission.outputRoute.rawValue
                ),
                debugLabel: scriptStage.stageID
            )
        )

        let promptVoiceSeed = TuringPromptVoiceSeedBuilder.composite(
            promptDescriptor,
            scriptVoiceSource: sourceText
        )

        async let promptPlan = voicePromptGenerator.generateVoicePrompt(
            VoicePromptRequest(
                id: promptDescriptor.voicePromptID,
                characterProfileID: promptDescriptor.characterProfileID,
                promptContext: promptVoiceSeed.promptContext,
                prerecordingTranscript: prerecording.transcript
            )
        )

        let resolvedLongform = try await longformPlan
        let resolvedPrompt = try await promptPlan

        let scriptSegments = resolvedLongform.flattenedSegments.map {
            TuringSpeechSegment(
                text: $0.spokenText,
                emotion: $0.emotion
            )
        }

        try Self.validateExactSource(
            sourceText: sourceText,
            segments: scriptSegments,
            scriptPointID: descriptor.scriptPointID
        )

        let segments = scriptSegments + resolvedPrompt.segments
        guard segments.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) composite pipeline returned no speech."
            )
        }

        return TuringFlowCompositeSpeechPlan(
            segments: segments,
            conversationSeed: resolvedPrompt.conversationSeed,
            promptVoiceSeed: promptVoiceSeed
        )
    }

    private static func validatePromptIdentity(
        _ prompt: TuringVoicePromptTriggerDescriptor,
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard prompt.speakerID == character.characterID,
              prompt.voiceID == character.voiceID,
              prompt.characterProfileID == character.characterID,
              prompt.conversationKey == descriptor.transmission.conversationKey,
              prompt.outputContext == descriptor.transmission.outputRoute else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) composite prompt identity mismatch."
            )
        }
    }

    private static func validateExactSource(
        sourceText: String,
        segments: [TuringSpeechSegment],
        scriptPointID: String
    ) throws {
        let source = normalizeForExactSource(sourceText)
        let spoken = normalizeForExactSource(
            segments.map(\.text).joined(separator: " ")
        )
        guard source == spoken else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "\(scriptPointID) Script Voice exact-source gate failed."
            )
        }
    }

    private static func normalizeForExactSource(_ text: String) -> String {
        var tokens: [String] = []
        var current = ""

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if current.isEmpty == false {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        if current.isEmpty == false {
            tokens.append(current)
        }

        return tokens.joined(separator: " ")
    }
}
