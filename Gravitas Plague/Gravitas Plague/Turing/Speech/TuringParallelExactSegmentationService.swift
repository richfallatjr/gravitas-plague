import Foundation

struct TuringParallelExactSegmentationService: Sendable {
    private let runner: any TuringFoundationQueryRunning
    private let limiter: FoundationConcurrencyLimiter

    init(
        runner: any TuringFoundationQueryRunning = FreshFoundationQueryRunner(),
        maxConcurrentFoundationJobs: Int = 4
    ) {
        self.runner = runner
        self.limiter = FoundationConcurrencyLimiter(
            maxPermits: maxConcurrentFoundationJobs
        )
    }

    func segmentStream(
        request: TuringLongformVoiceScriptRequest
    ) -> AsyncThrowingStream<TuringExactSpeechSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let jobs = TuringLongformTransportPlanner.makeJobs(
                        sourceText: request.sourceText
                    )
                    print("""
                    [TuringPhase1Longform] transport jobs planned
                      requestID: \(request.requestID)
                      sourceUTF16: \(request.sourceText.utf16.count)
                      estimatedTokens: \(TuringLongformTransportPlanner.estimatedTokens(request.sourceText))
                      jobCount: \(jobs.count)
                      maxConcurrentFoundationJobs: 4
                    """)

                    var bufferedResults: [Int: [TuringExactSpeechSegment]] = [:]
                    var nextChunkToEmit = 0
                    var globalIndex = 0

                    try await withThrowingTaskGroup(
                        of: TuringExactSegmentationChunkResult.self
                    ) { group in
                        for job in jobs {
                            group.addTask {
                                try await limiter.withPermit {
                                    try await segmentJob(
                                        job,
                                        request: request
                                    )
                                }
                            }
                        }

                        for try await result in group {
                            bufferedResults[result.chunkIndex] = result.segments

                            while let ready = bufferedResults.removeValue(
                                forKey: nextChunkToEmit
                            ) {
                                for segment in ready {
                                    continuation.yield(
                                        TuringExactSpeechSegment(
                                            globalIndex: globalIndex,
                                            chunkIndex: segment.chunkIndex,
                                            localIndex: segment.localIndex,
                                            absoluteStartUTF16: segment.absoluteStartUTF16,
                                            absoluteEndUTF16: segment.absoluteEndUTF16,
                                            text: segment.text,
                                            emotion: segment.emotion
                                        )
                                    )
                                    globalIndex += 1
                                }
                                nextChunkToEmit += 1
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func segmentAll(
        request: TuringLongformVoiceScriptRequest
    ) async throws -> [TuringExactSpeechSegment] {
        var segments: [TuringExactSpeechSegment] = []
        for try await segment in segmentStream(request: request) {
            segments.append(segment)
        }
        return segments
    }

    private func segmentJob(
        _ job: TuringExactSegmentationJob,
        request: TuringLongformVoiceScriptRequest
    ) async throws -> TuringExactSegmentationChunkResult {
        let prompt = try renderPrompt(
            job: job
        )

        print("""
        [TuringFoundation] longform exact segmentation job started
          freshSession: true
          requestID: \(request.requestID)
          chunkIndex: \(job.index)
          focusStartUTF16: \(job.focusStartUTF16)
          focusEndUTF16: \(job.focusEndUTF16)
        """)

        let raw = try await runner.runPrompt(
            prompt,
            purpose: "voiceScript_exactSegmentation_longform_focusChunk"
        )

        let payload = try await decodeOrRepair(
            raw: raw,
            job: job
        )
        let segments = try TuringExactSegmentationGate.gate(
            payload: payload,
            job: job,
            defaultEmotion: request.defaultEmotion
        )

        print("""
        [TuringFoundation] longform exact segmentation gate passed
          chunkIndex: \(job.index)
          segmentCount: \(segments.count)
        """)

        return TuringExactSegmentationChunkResult(
            chunkIndex: job.index,
            segments: segments
        )
    }

    private func decodeOrRepair(
        raw: String,
        job: TuringExactSegmentationJob
    ) async throws -> TuringExactSegmentationPayload {
        do {
            return try decodePayload(raw)
        } catch {
            let repairPrompt = """
            You repair JSON for an exact TTS segmentation job.

            Return JSON only. No markdown. No commentary. Do not add keys.
            Preserve spokenText exactly except for JSON escaping or syntax fixes.

            Required identifiers:
            chunkIndex: \(job.index)
            focusStartUTF16: \(job.focusStartUTF16)
            focusEndUTF16: \(job.focusEndUTF16)
            targetSeconds: 4.0
            maxSeconds: 5.0

            The previous response failed with:
            \(error.localizedDescription)

            Repair this payload:
            \"\"\"
            \(raw)
            \"\"\"
            """

            let repaired = try await runner.runPrompt(
                repairPrompt,
                purpose: "voiceScript_exactSegmentation_longform_jsonRepair"
            )
            return try decodePayload(repaired)
        }
    }

    private func decodePayload(
        _ raw: String
    ) throws -> TuringExactSegmentationPayload {
        let data = try TuringJSONSanitizer.extractSingleTopLevelObject(
            from: raw
        )
        return try JSONDecoder().decode(
            TuringExactSegmentationPayload.self,
            from: data
        )
    }

    private func renderPrompt(
        job: TuringExactSegmentationJob
    ) throws -> String {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Prompts/voiceScript_exactSegmentation_longform_focusChunk.txt"
        )
        var prompt = try String(contentsOf: url, encoding: .utf8)
        let replacements = [
            "{{chunkIndex}}": "\(job.index)",
            "{{focusStartUTF16}}": "\(job.focusStartUTF16)",
            "{{focusEndUTF16}}": "\(job.focusEndUTF16)",
            "{{prefixContext}}": job.prefixContext,
            "{{focusText}}": job.focusText,
            "{{suffixContext}}": job.suffixContext
        ]

        for (key, value) in replacements {
            prompt = prompt.replacingOccurrences(
                of: key,
                with: value
            )
        }

        return prompt
    }
}
