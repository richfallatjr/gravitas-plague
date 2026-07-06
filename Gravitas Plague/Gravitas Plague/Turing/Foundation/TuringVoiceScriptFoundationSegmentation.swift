import Foundation

struct TuringVoiceScriptFoundationSegment: Sendable, Hashable {
    let index: Int
    let spokenText: String
}

struct TuringVoiceScriptFoundationSegmentationReport: Sendable, Hashable {
    let sourceText: String
    let segments: [TuringVoiceScriptFoundationSegment]
    let exactCoveragePassed: Bool
}

struct TuringVoiceScriptFoundationSegmentationService: Sendable {
    private let runner: any TuringFoundationQueryRunning

    init(
        runner: any TuringFoundationQueryRunning = TuringFoundationModelsRunner()
    ) {
        self.runner = runner
    }

    func segmentExactSpeech(
        sourceText: String,
        requestID: String,
        emotion: String
    ) async throws -> TuringVoiceScriptFoundationSegmentationReport {
        let prompt = try Self.renderPrompt(
            resourcePath: "Turing/Prompts/voiceScript_exactSegmentation.txt",
            replacements: [
                "{{sourceText}}": sourceText
            ]
        )

        print("""
        [TuringPhase1] voiceScript requested
          requestID: \(requestID)
          sourceCharacters: \(sourceText.utf16.count)
          emotion: \(emotion)
        """)

        Self.logPrompt(
            prompt,
            name: "voiceScript_exactSegmentation"
        )

        let raw: String
        do {
            raw = try await runner.runPrompt(
                prompt,
                purpose: "voiceScript_exactSegmentation"
            )
        } catch {
            guard TuringFoundationGuardrailPolicy.isGuardrailError(error) else {
                throw error
            }
            print("""
            [TuringPhase1] Foundation guardrails triggered
              requestID: \(requestID)
              result: skipped
              qwenWillGenerateAutoResponse: false
              error: \(error.localizedDescription)
            """)
            return TuringVoiceScriptFoundationSegmentationReport(
                sourceText: sourceText,
                segments: [],
                exactCoveragePassed: false
            )
        }

        Self.logRawResponse(
            raw,
            name: "voiceScript_exactSegmentation",
            promptCharacters: prompt.utf16.count
        )

        let repair = FoundationVoiceScriptJSONRepairService(
            runner: runner
        )
        let payload: ExactSpeechSegmentationPayload
        do {
            payload = try await TuringJSONGate.decodeStrict(
                ExactSpeechSegmentationPayload.self,
                raw: raw,
                repairService: repair
            )
        } catch {
            guard TuringFoundationGuardrailPolicy.isGuardrailError(error) else {
                throw error
            }
            print("""
            [TuringPhase1] Foundation repair guardrails triggered
              requestID: \(requestID)
              result: skipped
              qwenWillGenerateAutoResponse: false
              error: \(error.localizedDescription)
            """)
            return TuringVoiceScriptFoundationSegmentationReport(
                sourceText: sourceText,
                segments: [],
                exactCoveragePassed: false
            )
        }

        let segments = try validatePayload(payload)
        let coveragePassed = exactCoveragePassed(
            sourceText: sourceText,
            segments: segments
        )

        print("""
        [TuringPhase1] Foundation exact segmentation passed
          requestID: \(requestID)
          sourceCharacters: \(sourceText.utf16.count)
          segmentCount: \(segments.count)
          exactCoverage: \(coveragePassed ? "passed" : "mismatchLogged")
          emotion: \(emotion)
        """)

        return TuringVoiceScriptFoundationSegmentationReport(
            sourceText: sourceText,
            segments: segments,
            exactCoveragePassed: coveragePassed
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

    private func validatePayload(
        _ payload: ExactSpeechSegmentationPayload
    ) throws -> [TuringVoiceScriptFoundationSegment] {
        guard payload.segments.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "segments must not be empty."
            )
        }

        return try payload.segments.enumerated().map { offset, segment in
            guard segment.index == offset else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Segment index \(segment.index) did not match expected \(offset)."
                )
            }

            let text = segment.spokenText
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard text.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Segment \(segment.index) was empty."
                )
            }

            return TuringVoiceScriptFoundationSegment(
                index: offset,
                spokenText: text
            )
        }
    }

    private func exactCoveragePassed(
        sourceText: String,
        segments: [TuringVoiceScriptFoundationSegment]
    ) -> Bool {
        let source = normalizeForCoverage(sourceText)
        let joined = normalizeForCoverage(
            segments.map(\.spokenText).joined(separator: " ")
        )
        return source == joined
    }

    private func normalizeForCoverage(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func logPrompt(
        _ prompt: String,
        name: String
    ) {
        print("""
        [TuringFoundationPrompt] BEGIN \(name)
        \(prompt)
        [TuringFoundationPrompt] END \(name)
        """)
        writeDebugLog(
            fileName: "last_\(name)_prompt.txt",
            contents: prompt
        )
    }

    private static func logRawResponse(
        _ raw: String,
        name: String,
        promptCharacters: Int
    ) {
        print("""
        [TuringFoundation] exact segmentation raw response received
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
}

private struct ExactSpeechSegmentationPayload: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let index: Int
        let spokenText: String
    }

    let version: Int?
    let targetSeconds: Double?
    let maxSeconds: Double?
    let segments: [Segment]
}

private struct FoundationVoiceScriptJSONRepairService: TuringJSONRepairService {
    let runner: any TuringFoundationQueryRunning

    func repairJSON(
        invalidPayload: String,
        errorDescription: String
    ) async throws -> String {
        let prompt = try TuringVoiceScriptFoundationSegmentationService
            .renderRepairPrompt(
                invalidPayload: invalidPayload,
                errorDescription: errorDescription
            )

        return try await runner.runPrompt(
            prompt,
            purpose: "voiceScript_jsonRepair"
        )
    }
}

private extension TuringVoiceScriptFoundationSegmentationService {
    static func renderRepairPrompt(
        invalidPayload: String,
        errorDescription: String
    ) throws -> String {
        try renderPrompt(
            resourcePath: "Turing/Prompts/voiceScript_jsonRepair.txt",
            replacements: [
                "{{errorDescription}}": errorDescription,
                "{{invalidPayload}}": invalidPayload
            ]
        )
    }
}
