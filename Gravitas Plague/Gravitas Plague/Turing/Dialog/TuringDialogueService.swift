import Foundation

actor TuringDialogueService {
    private let runner: any TuringFoundationQueryRunning
    private let characterStore: TuringCharacterProfileStore

    init(
        runner: any TuringFoundationQueryRunning = TuringFoundationModelsRunner(),
        characterStore: TuringCharacterProfileStore = TuringCharacterProfileStore()
    ) {
        self.runner = runner
        self.characterStore = characterStore
    }

    func generateVoicePrompt(
        _ request: VoicePromptRequest
    ) async throws -> TuringVoicePromptPlan {
        let profile = try characterStore.profile(
            id: request.characterProfileID
        )
        let prompt = try Self.renderPrompt(
            resourcePath: "Turing/Prompts/voicePrompt_characterIntent.txt",
            replacements: [
                "{{characterProfile}}": profile.promptText,
                "{{promptContext}}": request.promptContext,
                "{{prerecordingTranscript}}": request.prerecordingTranscript
            ]
        )

        print("""
        [TuringVoicePrompt] Foundation request started
          freshSession: true
          id: \(request.id)
          characterID: \(profile.characterID)
          promptTemplate: voicePrompt_characterIntent
          profileContext: fullAuthoredCharacterProfile
          inputContract: characterProfile,promptContext,prerecordingTranscript
          prerecordingTranscriptUTF16: \(request.prerecordingTranscript.utf16.count)
          authoredPRTranscriptSHA256: \(TuringFlowHash.sha256(request.prerecordingTranscript))
          dialogueHistoryIncluded: false
          conversationSeedIncluded: false
        """)

        let raw: String
        do {
            raw = try await runner.runPrompt(
                prompt,
                purpose: "voicePrompt_characterIntent"
            )
        } catch {
            guard TuringFoundationGuardrailPolicy.isGuardrailError(error) else {
                throw error
            }
            print("""
            [TuringVoicePrompt] Foundation guardrails triggered
              characterID: \(profile.characterID)
              result: failed
              qwenWillGenerateAutoResponse: false
              error: \(error.localizedDescription)
            """)
            throw TuringRuntimeError.foundationJSONGateFailed(
                "voicePrompt guardrails triggered: \(error.localizedDescription)"
            )
        }
        Self.logRawResponse(
            raw,
            name: "voicePrompt_characterIntent",
            promptCharacters: prompt.utf16.count
        )
        let plan: TuringVoicePromptPlan
        do {
            plan = try await decodeVoicePromptPlanWithOneRepair(
                raw: raw,
                purpose: "TuringVoicePrompt"
            )
        } catch {
            guard TuringFoundationGuardrailPolicy.isGuardrailError(error) else {
                throw error
            }
            print("""
            [TuringVoicePrompt] Foundation repair guardrails triggered
              characterID: \(profile.characterID)
              result: failed
              qwenWillGenerateAutoResponse: false
              error: \(error.localizedDescription)
            """)
            throw TuringRuntimeError.foundationRepairFailed(
                "voicePrompt repair guardrails triggered: \(error.localizedDescription)"
            )
        }

        print("""
        [TuringVoicePrompt] gate passed
          segmentCount: \(plan.segments.count)
          conversationSeed: present
          seedID: \(plan.conversationSeed.seedID)
        """)
        Self.logAcceptedSegments(
            purpose: "TuringVoicePrompt",
            segments: plan.segments
        )
        for (index, segment) in plan.segments.enumerated() {
            print("""
            [TuringFlow] Foundation response segment accepted
              requestID: \(request.id)
              segmentIndex: \(index)
              foundationSegmentTextSHA256: \(TuringFlowHash.sha256(segment.text))
            """)
        }

        return plan
    }

    func generateConversationNoBible(
        _ request: ConversationPromptNoBibleRequest
    ) async throws -> TuringDialoguePlan {
        let profile = try characterStore.profile(
            id: request.characterProfileID
        )
        let prompt = try Self.renderPrompt(
            resourcePath: "Turing/Prompts/conversationPrompt_playerTurn_noBible.txt",
            replacements: [
                "{{characterProfile}}": profile.promptText,
                "{{promptContext}}": request.promptContext,
                "{{prerecordingTranscript}}": request.prerecordingTranscript,
                "{{userInput}}": request.userInput
            ]
        )

        print("""
        [TuringConversationNoBible] Foundation request started
          freshSession: true
          characterID: \(profile.characterID)
          promptTemplate: conversationPrompt_playerTurn_noBible
          inputContract: userInput,characterProfile,promptVoiceSeed,prerecordingTranscript
          prerecordingTranscriptUTF16: \(request.prerecordingTranscript.utf16.count)
          dialogueHistoryIncluded: false
          promptVoiceSeedIncluded: true
          promptVoiceID: \(request.promptVoiceID)
          generatedConversationSeedIncluded: false
          promptContextSource: authoredPromptVoiceSeed
          promptContextSHA256: \(TuringFlowHash.sha256(request.promptContext))
        """)

        let raw: String
        do {
            raw = try await runner.runPrompt(
                prompt,
                purpose: "conversationPrompt_playerTurn_noBible"
            )
        } catch {
            if TuringFoundationGuardrailPolicy.isGuardrailError(error) {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "conversationPrompt guardrails triggered: \(error.localizedDescription)"
                )
            }
            throw error
        }

        Self.logRawResponse(
            raw,
            name: "conversationPrompt_playerTurn_noBible",
            promptCharacters: prompt.utf16.count
        )

        let plan = try await decodePlanWithOneRepair(
            raw: raw,
            purpose: "TuringConversationNoBible"
        )

        print("""
        [TuringConversationNoBible] gate passed
          segmentCount: \(plan.segments.count)
        """)
        Self.logAcceptedSegments(
            purpose: "TuringConversationNoBible",
            segments: plan.segments
        )

        return plan
    }

    private func decodePlanWithOneRepair(
        raw: String,
        purpose: String
    ) async throws -> TuringDialoguePlan {
        do {
            return try Self.decodeStrictPlan(raw)
        } catch {
            let repairService = TuringDialogueJSONRepairService(
                runner: runner
            )
            let repaired = try await repairService.repairJSON(
                invalidPayload: raw,
                errorDescription: error.localizedDescription
            )
            do {
                return try Self.decodeStrictPlan(repaired)
            } catch {
                throw TuringRuntimeError.foundationRepairFailed(
                    "\(purpose): \(error.localizedDescription)"
                )
            }
        }
    }

    private func decodeVoicePromptPlanWithOneRepair(
        raw: String,
        purpose: String
    ) async throws -> TuringVoicePromptPlan {
        do {
            return try Self.decodeStrictVoicePromptPlan(raw)
        } catch {
            let repairService = TuringDialogueJSONRepairService(
                runner: runner,
                expectedSchema: Self.voicePromptPlanRepairSchema
            )
            let repaired = try await repairService.repairJSON(
                invalidPayload: raw,
                errorDescription: error.localizedDescription
            )
            do {
                return try Self.decodeStrictVoicePromptPlan(repaired)
            } catch {
                throw TuringRuntimeError.foundationRepairFailed(
                    "\(purpose): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func decodeStrictPlan(
        _ raw: String
    ) throws -> TuringDialoguePlan {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
            from: raw
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Top-level response must be a JSON object."
            )
        }

        let allowedKeys: Set<String> = [
            "schemaVersion",
            "segments"
        ]
        let extraKeys = Set(dictionary.keys).subtracting(allowedKeys)
        guard extraKeys.isEmpty else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Unexpected top-level keys: \(extraKeys.sorted().joined(separator: ", "))."
            )
        }

        let decoded = try JSONDecoder().decode(
            TuringDialoguePlan.self,
            from: data
        )

        guard decoded.schemaVersion == 1 else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "schemaVersion must be 1."
            )
        }
        guard decoded.segments.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "segments must not be empty."
            )
        }
        guard decoded.segments.count <= 8 else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "segments must contain 8 or fewer items."
            )
        }

        let normalizedSegments = try decoded.segments.enumerated().map { index, segment in
            let text = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let emotion = segment.emotion.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            guard text.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Segment \(index) text must not be empty."
                )
            }
            guard emotion.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Segment \(index) emotion must not be empty."
                )
            }

            return TuringSpeechSegment(
                text: text,
                emotion: emotion
            )
        }

        return TuringDialoguePlan(
            schemaVersion: decoded.schemaVersion,
            segments: normalizedSegments
        )
    }

    private static func decodeStrictVoicePromptPlan(
        _ raw: String
    ) throws -> TuringVoicePromptPlan {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
            from: raw
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Top-level response must be a JSON object."
            )
        }

        let allowedKeys: Set<String> = [
            "schemaVersion",
            "segments",
            "conversationSeed"
        ]
        let extraKeys = Set(dictionary.keys).subtracting(allowedKeys)
        guard extraKeys.isEmpty else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Unexpected top-level keys: \(extraKeys.sorted().joined(separator: ", "))."
            )
        }

        let decoded = try JSONDecoder().decode(
            TuringVoicePromptPlan.self,
            from: data
        )

        guard decoded.schemaVersion == 1 else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "schemaVersion must be 1."
            )
        }
        guard decoded.segments.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "segments must not be empty."
            )
        }
        guard decoded.segments.count <= 8 else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "segments must contain 8 or fewer items."
            )
        }

        let normalizedSegments = try decoded.segments.enumerated().map { index, segment in
            let text = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let emotion = segment.emotion.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            guard text.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Segment \(index) text must not be empty."
                )
            }
            guard emotion.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Segment \(index) emotion must not be empty."
                )
            }

            return TuringSpeechSegment(
                text: text,
                emotion: emotion
            )
        }

        let seed = decoded.conversationSeed
        let normalizedSeed = TuringConversationSeed(
            seedID: seed.seedID.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: seed.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            currentAttitude: seed.currentAttitude.trimmingCharacters(in: .whitespacesAndNewlines),
            recentFacts: seed.recentFacts.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { $0.isEmpty == false },
            openThread: seed.openThread.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard normalizedSeed.summary.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "conversationSeed.summary must not be empty."
            )
        }
        guard normalizedSeed.openThread.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "conversationSeed.openThread must not be empty."
            )
        }

        return TuringVoicePromptPlan(
            schemaVersion: decoded.schemaVersion,
            segments: normalizedSegments,
            conversationSeed: normalizedSeed
        )
    }

    private static func renderPrompt(
        resourcePath: String,
        replacements: [String: String]
    ) throws -> String {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: resourcePath
        )
        var prompt = try String(contentsOf: url, encoding: .utf8)

        for (key, value) in replacements {
            prompt = prompt.replacingOccurrences(
                of: key,
                with: value
            )
        }

        return prompt
    }

    private static func logAcceptedSegments(
        purpose: String,
        segments: [TuringSpeechSegment]
    ) {
        for (index, segment) in segments.enumerated() {
            print("""
            [\(purpose)] accepted segment
              index: \(index)
              textUTF16: \(segment.text.utf16.count)
              emotion: \(segment.emotion)
              text: \(segment.text)
            """)
        }
    }

    private static func logRawResponse(
        _ raw: String,
        name: String,
        promptCharacters: Int
    ) {
        print("""
        [TuringFoundation] dialogue raw response received
          promptCharacters: \(promptCharacters)
          responseCharacters: \(raw.utf16.count)
          freshSession: true
        [TuringFoundationRawResponse] BEGIN \(name)
        \(raw)
        [TuringFoundationRawResponse] END \(name)
        """)
        writeDebugLog(
            fileName: "last_\(name)_raw_response.txt",
            contents: raw
        )
    }

    private static func writeDebugLog(
        fileName: String,
        contents: String
    ) {
        do {
            let directory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(
                "TuringFoundationLogs",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(fileName)
            try contents.write(to: url, atomically: true, encoding: .utf8)

            print("""
            [TuringFoundationLog] wrote \(fileName)
              path: \(url.path)
            """)
        } catch {
            print("""
            [TuringFoundationLog] write failed
              fileName: \(fileName)
              error: \(error.localizedDescription)
            """)
        }
    }

    fileprivate static let dialoguePlanRepairSchema = """
    {
      "schemaVersion": 1,
      "segments": [
        {
          "text": "string",
          "emotion": "string"
        }
      ]
    }
    """

    fileprivate static let voicePromptPlanRepairSchema = """
    {
      "schemaVersion": 1,
      "segments": [
        {
          "text": "string",
          "emotion": "string"
        }
      ],
      "conversationSeed": {
        "seedID": "string",
        "summary": "string",
        "currentAttitude": "string",
        "recentFacts": ["string"],
        "openThread": "string"
      }
    }
    """
}

private struct TuringDialogueJSONRepairService: TuringJSONRepairService {
    let runner: any TuringFoundationQueryRunning
    var expectedSchema = TuringDialogueService.dialoguePlanRepairSchema

    func repairJSON(
        invalidPayload: String,
        errorDescription: String
    ) async throws -> String {
        let prompt = """
        You repair JSON for a Gravitas Plague character dialogue response.

        Return JSON only. No markdown. No commentary. Do not add keys.

        The only valid schema is:
        \(expectedSchema)

        The previous response failed with:
        \(errorDescription)

        Repair this payload without rewriting the intended character speech:
        \"\"\"
        \(invalidPayload)
        \"\"\"
        """

        return try await runner.runPrompt(
            prompt,
            purpose: "turingDialogue_jsonRepair"
        )
    }
}
