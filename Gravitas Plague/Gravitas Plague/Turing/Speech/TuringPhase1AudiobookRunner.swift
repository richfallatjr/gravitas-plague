import Foundation

struct TuringPhase1AudiobookRunner: Sendable {
    private let runner: any TuringFoundationQueryRunning
    private let policy: TuringAudiobookSourceSectionPolicy
    private let contextUTF16Length = 600
    private let maxLLMInFlight = 1

    init(
        runner: any TuringFoundationQueryRunning = FreshFoundationQueryRunner(),
        policy: TuringAudiobookSourceSectionPolicy = .init()
    ) {
        self.runner = runner
        self.policy = policy
    }

    func makePlan(
        request: TuringLongformVoiceScriptRequest
    ) async throws -> TuringPhase1AudiobookPlan {
        let plan = try makeSourcePlan(request: request)
        var sectionResults: [TuringAudiobookSectionSegmentationResult] = []
        sectionResults.reserveCapacity(plan.sections.count)
        for section in plan.sections {
            sectionResults.append(
                try await prepareSection(
                    section,
                    in: plan,
                    request: request
                )
            )
        }
        let audiobookPlan = TuringPhase1AudiobookPlan(
            normalizedSourceText: plan.normalizedSourceText,
            sections: renumberSectionResults(sectionResults)
        )
        TuringAudiobookSegmentationParser.noteGlobalSemanticValidationSkipped(
            audiobookPlan
        )

        print("""
        [TuringPhase1Audiobook] section segmentation accepted before Qwen
          sectionCount: \(audiobookPlan.sections.count)
          segmentCount: \(audiobookPlan.segmentCount)
          semanticValidation: disabled
        """)

        return audiobookPlan
    }

    func makeSourcePlan(
        request: TuringLongformVoiceScriptRequest
    ) throws -> TuringAudiobookSourcePlan {
        let normalized = TuringAudiobookSourceNormalizer.normalize(
            request.sourceText
        )
        print("""
        [TuringPhase1Audiobook] source normalized
          requestID: \(request.requestID)
          normalizedUTF16: \(normalized.utf16.count)
        """)

        let sourceSections = try TuringAudiobookSourceSectioner.makeSections(
            normalizedSource: normalized,
            policy: policy
        )

        print("""
        [TuringPhase1Audiobook] source sections planned
          sectionCount: \(sourceSections.count)
          targetWords: \(policy.targetWords)
          minWords: \(policy.minWords)
          maxWords: \(policy.maxWords)
          maxChars: \(policy.maxChars)
          rollingWindow: currentPlusNext
          maxLLMInFlight: \(maxLLMInFlight)
        """)

        for section in sourceSections {
            let sectionText = TuringAudiobookSourceSectioner.sourceText(
                for: section,
                in: normalized
            )
            print("""
            [TuringPhase1Audiobook] source section planned
              sectionIndex: \(section.index)
              sourceStartUTF16: \(section.sourceStartUTF16)
              sourceEndUTF16: \(section.sourceEndUTF16)
              estimatedWordCount: \(section.estimatedWordCount)
              sectionText:
            ---BEGIN_TURING_AUDIOBOOK_SOURCE_SECTION---
            \(sectionText)
            ---END_TURING_AUDIOBOOK_SOURCE_SECTION---
            """)
        }

        return TuringAudiobookSourcePlan(
            normalizedSourceText: normalized,
            sections: sourceSections
        )
    }

    func prepareSection(
        _ section: TuringAudiobookSourceSection,
        in plan: TuringAudiobookSourcePlan,
        request: TuringLongformVoiceScriptRequest
    ) async throws -> TuringAudiobookSectionSegmentationResult {
        let sectionText = TuringAudiobookSourceSectioner.sourceText(
            for: section,
            in: plan.normalizedSourceText
        )
        let previousContextTail = previousContextTail(
            before: section,
            in: plan.normalizedSourceText
        )
        let nextContextHead = nextContextHead(
            after: section,
            in: plan.normalizedSourceText
        )
        let prompt = try renderPrompt(
            section: section,
            previousContextTail: previousContextTail,
            sectionText: sectionText,
            nextContextHead: nextContextHead
        )

        print("""
        [TuringFoundation] audiobook section segmentation started
          freshSession: true
          requestID: \(request.requestID)
          sectionIndex: \(section.index)
          sourceUTF16: \(sectionText.utf16.count)
          wordCount: \(section.estimatedWordCount)
          previousContextTailUTF16: \(previousContextTail.utf16.count)
          nextContextHeadUTF16: \(nextContextHead.utf16.count)
        """)

        let raw = try await runner.runPrompt(
            prompt,
            purpose: "voiceScript_audiobookSourceSectionSegmentation"
        )
        Self.logRawResponse(
            raw,
            name: "voiceScript_audiobook_section_\(section.index)",
            sectionIndex: section.index,
            promptCharacters: prompt.utf16.count
        )

        do {
            return try decodeSegmentationResult(raw, section: section)
        } catch {
            print("""
            [TuringFoundation] audiobook section JSON repair started
              freshSession: true
              sectionIndex: \(section.index)
              reason: malformedJSON
            """)

            do {
                let repaired = try await runner.runPrompt(
                    renderRepairPrompt(
                        section: section,
                        previousContextTail: previousContextTail,
                        sectionText: sectionText,
                        nextContextHead: nextContextHead,
                        previousError: error
                    ),
                    purpose: "voiceScript_audiobookSourceSectionSegmentationRepair"
                )
                Self.logRawResponse(
                    repaired,
                    name: "voiceScript_audiobook_section_\(section.index)_repair",
                    sectionIndex: section.index,
                    promptCharacters: prompt.utf16.count
                )
                return try decodeSegmentationResult(repaired, section: section)
            } catch {
                print("""
                [TuringPhase1Audiobook] section failed before Qwen
                  sectionIndex: \(section.index)
                  qwenStarted: false
                  error: \(error.localizedDescription)
                """)
                throw error
            }
        }
    }

    private func decodeSegmentationResult(
        _ raw: String,
        section: TuringAudiobookSourceSection
    ) throws -> TuringAudiobookSectionSegmentationResult {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
            from: raw
        )
        let payload = try JSONDecoder().decode(
            TuringAudiobookSegmentationPayload.self,
            from: data
        )
        let parser = TuringAudiobookSegmentationParser(
            expectedSection: section,
            globalIndexOffset: 0
        )
        let segments = parser.parseAcceptedSegments(payload)

        print("""
        [TuringFoundation] audiobook section segmentation accepted
          sectionIndex: \(section.index)
          segmentCount: \(segments.count)
          semanticValidation: disabled
        """)
        Self.logAcceptedSegments(
            sectionIndex: section.index,
            segments: segments
        )

        return TuringAudiobookSectionSegmentationResult(
            section: section,
            segments: segments
        )
    }

    private func renumberSectionResults(
        _ results: [TuringAudiobookSectionSegmentationResult]
    ) -> [TuringAudiobookSectionSegmentationResult] {
        var globalIndex = 0
        return results.map { result in
            let renumbered = renumberSectionResult(
                result,
                startingGlobalIndex: globalIndex
            )
            globalIndex += renumbered.segments.count
            return renumbered
        }
    }

    private func renumberSectionResult(
        _ result: TuringAudiobookSectionSegmentationResult,
        startingGlobalIndex: Int
    ) -> TuringAudiobookSectionSegmentationResult {
        var globalIndex = startingGlobalIndex
        let renumberedSegments = result.segments.map { segment in
            defer { globalIndex += 1 }
            return TuringAudiobookSpeechSegment(
                globalIndex: globalIndex,
                sectionIndex: segment.sectionIndex,
                localIndex: segment.localIndex,
                spokenText: segment.spokenText,
                emotion: segment.emotion
            )
        }
        return TuringAudiobookSectionSegmentationResult(
            section: result.section,
            segments: renumberedSegments
        )
    }

    private func renderPrompt(
        section: TuringAudiobookSourceSection,
        previousContextTail: String,
        sectionText: String,
        nextContextHead: String
    ) throws -> String {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Prompts/voiceScript_audiobookSourceSectionSegmentation.txt"
        )
        var prompt = try String(contentsOf: url, encoding: .utf8)
        prompt = prompt.replacingOccurrences(
            of: "{{sectionIndex}}",
            with: "\(section.index)"
        )
        prompt = prompt.replacingOccurrences(
            of: "{{sectionText}}",
            with: sectionText
        )
        prompt = prompt.replacingOccurrences(
            of: "{{previousContextTail}}",
            with: previousContextTail
        )
        prompt = prompt.replacingOccurrences(
            of: "{{nextContextHead}}",
            with: nextContextHead
        )
        return prompt
    }

    private static func logAcceptedSegments(
        sectionIndex: Int,
        segments: [TuringAudiobookSpeechSegment]
    ) {
        for segment in segments {
            print("""
            [TuringFoundation] audiobook accepted segment
              sectionIndex: \(sectionIndex)
              localIndex: \(segment.localIndex)
              globalIndex: \(segment.globalIndex)
              spokenUTF16: \(segment.spokenText.utf16.count)
              emotion: \(segment.emotion)
              spokenText:
            ---BEGIN_TURING_AUDIOBOOK_SPOKEN_SEGMENT---
            \(segment.spokenText)
            ---END_TURING_AUDIOBOOK_SPOKEN_SEGMENT---
            """)
        }
    }

    private static func logRawResponse(
        _ raw: String,
        name: String,
        sectionIndex: Int,
        promptCharacters: Int
    ) {
        print("""
        [TuringFoundation] audiobook raw response received
          sectionIndex: \(sectionIndex)
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

    private func renderRepairPrompt(
        section: TuringAudiobookSourceSection,
        previousContextTail: String,
        sectionText: String,
        nextContextHead: String,
        previousError: Error
    ) -> String {
        """
        Repair the audiobook source-section segmentation JSON.

        Return JSON only. No markdown. No commentary.
        The previous response failed with: \(previousError.localizedDescription)

        Required schema:
        {
          "schemaVersion": 1,
          "sectionIndex": \(section.index),
          "segments": [
            {
              "index": 0,
              "spokenText": "string sent to Qwen",
              "emotion": "narration"
            }
          ]
        }

        Rules:
        - Repair malformed JSON only.
        - Return ordered spoken segments.
        - Do not include sourceText.
        - Only return segments for the section text.

        Previous context tail, read-only:
        ---BEGIN_PREVIOUS_CONTEXT_TAIL---
        \(previousContextTail)
        ---END_PREVIOUS_CONTEXT_TAIL---

        Section text to segment:
        ---BEGIN_SECTION_TEXT---
        \(sectionText)
        ---END_SECTION_TEXT---

        Next context head, read-only:
        ---BEGIN_NEXT_CONTEXT_HEAD---
        \(nextContextHead)
        ---END_NEXT_CONTEXT_HEAD---
        """
    }

    private func previousContextTail(
        before section: TuringAudiobookSourceSection,
        in source: String
    ) -> String {
        let start = max(0, section.sourceStartUTF16 - contextUTF16Length)
        return substring(
            source,
            startUTF16: start,
            endUTF16: section.sourceStartUTF16
        )
    }

    private func nextContextHead(
        after section: TuringAudiobookSourceSection,
        in source: String
    ) -> String {
        let end = min(
            source.utf16.count,
            section.sourceEndUTF16 + contextUTF16Length
        )
        return substring(
            source,
            startUTF16: section.sourceEndUTF16,
            endUTF16: end
        )
    }

    private func substring(
        _ source: String,
        startUTF16: Int,
        endUTF16: Int
    ) -> String {
        guard startUTF16 < endUTF16 else {
            return ""
        }
        let start = String.Index(utf16Offset: startUTF16, in: source)
        let end = String.Index(utf16Offset: endUTF16, in: source)
        return String(source[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
