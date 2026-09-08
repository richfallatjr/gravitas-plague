import Foundation
import MLX
#if canImport(Metal)
import Metal
#endif

public struct TuringQwenOptimizationBenchmarkOptions: Sendable {
    public let modelRoot: URL
    public let bundleRoot: URL
    public let suite: TuringQwenBenchmarkSuite
    public let label: String
    public let gitRevision: String?
    public let baseline: TuringQwenOptimizationBenchmarkReport?

    public init(
        modelRoot: URL,
        bundleRoot: URL,
        suite: TuringQwenBenchmarkSuite,
        label: String,
        gitRevision: String? = nil,
        baseline: TuringQwenOptimizationBenchmarkReport? = nil
    ) {
        self.modelRoot = modelRoot
        self.bundleRoot = bundleRoot
        self.suite = suite
        self.label = label
        self.gitRevision = gitRevision
        self.baseline = baseline
    }
}

public enum TuringQwenOptimizationBenchmarkRunner {
    public static let voiceID = "big_mike_base_clone_v1"
    public static let variantID = "broadcast_reference_fast_01"
    public static let warmupText = "Big Mike, hold the line and confirm this warmup signal."
    public static let samplingSeed: UInt64 = 0x4752_4156_4954_4153
    public static let maxNewRowsPerSegment = 160
    static let minimumThroughputGainPercent = 10.0

    static func unavailableLazyMLXStageTiming()
        -> TuringQwenBenchmarkMeasurement<Double>
    {
        .unavailable(
            "Host-side talker/code-predictor timers bracket lazy MLX graph construction, " +
                "not completed GPU execution; downstream evaluation can attribute one " +
                "stage's work to another."
        )
    }

    static func unavailableTotalSynchronizationBarrierCount()
        -> TuringQwenBenchmarkMeasurement<Int>
    {
        .unavailable(
            "The baseline runtime exposes no complete count of MLX evaluation/" +
                "synchronization barriers."
        )
    }

    static func unavailableCompletedFirstSemanticRowTiming()
        -> TuringQwenBenchmarkMeasurement<Double>
    {
        .unavailable(
            "The baseline runtime exposes no completion-observed request-to-first-" +
                "semantic-row timestamp; lazy graph construction/token selection cannot " +
                "stand in for completed MLX execution."
        )
    }

    static func unavailableTokenMaterializationTiming()
        -> TuringQwenBenchmarkMeasurement<Double>
    {
        .unavailable(
            "The baseline runtime exposes no isolated token-materialization completion " +
                "timing."
        )
    }

    static func unavailableHostReadbackElementCount()
        -> TuringQwenBenchmarkMeasurement<Int>
    {
        .unavailable(
            "The baseline runtime exposes no complete host-readback element count."
        )
    }

    public static func run(
        options: TuringQwenOptimizationBenchmarkOptions
    ) async -> TuringQwenOptimizationBenchmarkReport {
        let cases = TuringQwenOptimizationBenchmarkCorpus.cases(for: options.suite)
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let device = deviceIdentity()
        let build = buildIdentity(
            gitRevision: options.gitRevision,
            executable: CommandLine.arguments.first,
            repositoryStartURL: options.bundleRoot
        )
        let configuration = benchmarkConfiguration(suite: options.suite)

        do {
            let loadedProfile = try TuringQwenNativeCloneProfileLoader()
                .loadBigMikeBaseCloneProfile(
                    from: options.bundleRoot,
                    voiceID: voiceID
                )
            _ = try loadedProfile.requireVariant(variantID)
            let profile = lockedProfile(from: loadedProfile)
            let config = try TuringQwenNativeConfig.load(from: options.modelRoot)
            try config.validateBaseCloneRuntime()
            let model = modelIdentity(
                modelRoot: options.modelRoot,
                profile: profile,
                config: config
            )

            return try await execute(
                options: options,
                cases: cases,
                generatedAt: generatedAt,
                model: model,
                device: device,
                build: build,
                profile: profile
            )
        } catch {
            let results = cases.map { failedResult(for: $0, error: nil, skipped: true) }
            let aggregate = aggregate(results)
            let model = unavailableModelIdentity(modelRoot: options.modelRoot)
            let comparison = comparison(
                baseline: options.baseline,
                currentLabel: options.label,
                currentAggregate: aggregate,
                currentResults: results,
                currentModel: model,
                currentDevice: device,
                currentBuild: build,
                currentConfiguration: configuration
            )
            let reasons = [
                "Benchmark setup failed: \(error.localizedDescription)"
            ] + comparisonAcceptanceFailureReasons(comparison)
            return TuringQwenOptimizationBenchmarkReport(
                schemaVersion: 2,
                generatedAtUTC: generatedAt,
                label: options.label,
                model: model,
                device: device,
                build: build,
                configuration: configuration,
                warmup: .unavailable("Benchmark setup failed before warmup: \(error.localizedDescription)"),
                results: results,
                aggregate: aggregate,
                comparison: comparison,
                completion: TuringQwenBenchmarkCompletion(
                    status: .fail,
                    reasons: reasons
                )
            )
        }
    }

    private static func execute(
        options: TuringQwenOptimizationBenchmarkOptions,
        cases: [TuringQwenBenchmarkCase],
        generatedAt: String,
        model: TuringQwenBenchmarkModelIdentity,
        device: TuringQwenBenchmarkDeviceIdentity,
        build: TuringQwenBenchmarkBuildIdentity,
        profile: TuringQwenNativeCloneProfile
    ) async throws -> TuringQwenOptimizationBenchmarkReport {
        let residencyPool = try TuringQwenNativeGenerationSchedulerFactory.makeFresh2Pool(
            residencyMode: .sharedImmutableFresh2,
            recoveryRunID: "optimization-benchmark"
        )
        let warmLoadStartedAt = Date()
        try await residencyPool.warmLoadExactlyRequestedInstances(
            modelRoot: options.modelRoot,
            cloneProfile: profile,
            variantID: variantID,
            performanceMode: .performance
        )
        let warmLoadSeconds = Date().timeIntervalSince(warmLoadStartedAt)

        let instance = try await residencyPool.checkout()
        let instanceSnapshot = try await instance.residencySnapshot()
        let releaseLedger = TuringQwenRenderReleaseLedger()
        let renderPhaseState = TuringQwenRenderPhaseState()
        let admissionPolicy = try TuringQwenNativeGPUAdmissionPolicy.currentProduction
        let gpuAdmission = TuringQwenNativeGPUAdmissionController(policy: admissionPolicy)
        let runID = "optimization-benchmark-\(UUID().uuidString.lowercased())"
        try await renderPhaseState.beginRun(runID: runID)
        await gpuAdmission.beginRun(runID: runID)
        let decoder = TuringQwenNativeSpeechDecodeCoordinator(
            releaseLedger: releaseLedger,
            renderPhaseState: renderPhaseState,
            gpuAdmission: gpuAdmission,
            residencySnapshots: [instanceSnapshot]
        )
        let decoderToken = try await decoder.beginRun(
            runID: runID,
            modelRoot: options.modelRoot
        )

        var nextSegmentIndex = 0
        var results: [TuringQwenBenchmarkResult] = []
        var fatalError: Error?
        var warmupMeasurement: TuringQwenBenchmarkMeasurement<Double>

        do {
            let warmupCase = TuringQwenBenchmarkCase(
                id: "warmup",
                tier: .short,
                segments: [warmupText]
            )
            let warmup = try await executeCase(
                warmupCase,
                instance: instance,
                runID: runID,
                startingSegmentIndex: nextSegmentIndex,
                profile: profile,
                releaseLedger: releaseLedger,
                renderPhaseState: renderPhaseState,
                gpuAdmission: gpuAdmission,
                decoder: decoder,
                decoderToken: decoderToken
            )
            nextSegmentIndex += warmupCase.segments.count
            guard warmup.status == .passed else {
                throw TuringQwenNativeError.invalidConfig(
                    "The fixed Big Mike warmup failed."
                )
            }
            warmupMeasurement = warmup.timing.totalWallSeconds
        } catch {
            warmupMeasurement = .unavailable(
                "Fixed Big Mike warmup failed: \(error.localizedDescription)"
            )
            fatalError = error
        }

        if fatalError == nil {
            for (caseOffset, benchmarkCase) in cases.enumerated() {
                do {
                    let result = try await executeCase(
                        benchmarkCase,
                        instance: instance,
                        runID: runID,
                        startingSegmentIndex: nextSegmentIndex,
                        profile: profile,
                        releaseLedger: releaseLedger,
                        renderPhaseState: renderPhaseState,
                        gpuAdmission: gpuAdmission,
                        decoder: decoder,
                        decoderToken: decoderToken
                    )
                    nextSegmentIndex += benchmarkCase.segments.count
                    results.append(result)
                    if result.status != .passed {
                        fatalError = TuringQwenNativeError.invalidConfig(
                            "Benchmark quality gate failed for \(benchmarkCase.id)."
                        )
                    }
                } catch {
                    results.append(failedResult(for: benchmarkCase, error: error))
                    fatalError = error
                }

                if fatalError != nil {
                    for remaining in cases.dropFirst(caseOffset + 1) {
                        results.append(failedResult(for: remaining, error: nil, skipped: true))
                    }
                    break
                }
            }
        } else {
            results = cases.map { failedResult(for: $0, error: nil, skipped: true) }
        }

        await decoder.finishRun(decoderToken)
        await releaseLedger.clearRun(runID)
        let admissionEndError: Error?
        do {
            _ = try await gpuAdmission.finishRun(reason: "optimizationBenchmarkFinished")
            admissionEndError = nil
        } catch {
            admissionEndError = error
        }
        await residencyPool.checkin(instance)
        await residencyPool.unloadAll(reason: "optimizationBenchmarkFinished")

        let resultAggregate = aggregate(results)
        let configuration = benchmarkConfiguration(suite: options.suite)
        let resultComparison = comparison(
            baseline: options.baseline,
            currentLabel: options.label,
            currentAggregate: resultAggregate,
            currentResults: results,
            currentModel: model,
            currentDevice: device,
            currentBuild: build,
            currentConfiguration: configuration
        )
        var reasons: [String] = []
        if let fatalError {
            reasons.append("Stopped after first failure: \(fatalError.localizedDescription)")
        }
        if let admissionEndError {
            reasons.append("GPU admission did not finish cleanly: \(admissionEndError.localizedDescription)")
        }
        if resultAggregate.failedCaseCount > 0 {
            reasons.append("\(resultAggregate.failedCaseCount) selected corpus case(s) failed or were skipped.")
        }
        if (resultAggregate.commandBufferFailures.value ?? 0) > 0 {
            reasons.append("One or more Metal command buffers failed.")
        }
        reasons.append(contentsOf: comparisonAcceptanceFailureReasons(resultComparison))

        return TuringQwenOptimizationBenchmarkReport(
            schemaVersion: 2,
            generatedAtUTC: generatedAt,
            label: options.label,
            model: model,
            device: device,
            build: build,
            configuration: configuration,
            warmup: warmupMeasurement.value.map {
                .measured(
                    $0,
                    detail: "Inference warmup seconds. Residency warm-load took \(format(warmLoadSeconds)) seconds and is excluded."
                )
            } ?? warmupMeasurement,
            results: results,
            aggregate: resultAggregate,
            comparison: resultComparison,
            completion: TuringQwenBenchmarkCompletion(
                status: reasons.isEmpty ? .pass : .fail,
                reasons: reasons.isEmpty
                    ? [completionSuccessReason(comparison: resultComparison)]
                    : reasons
            )
        )
    }

    private static func executeCase(
        _ benchmarkCase: TuringQwenBenchmarkCase,
        instance: TuringQwenNativeFreshInstance,
        runID: String,
        startingSegmentIndex: Int,
        profile: TuringQwenNativeCloneProfile,
        releaseLedger: TuringQwenRenderReleaseLedger,
        renderPhaseState: TuringQwenRenderPhaseState,
        gpuAdmission: TuringQwenNativeGPUAdmissionController,
        decoder: TuringQwenNativeSpeechDecodeCoordinator,
        decoderToken: TuringQwenNativeSpeechDecodeCoordinator.RunToken
    ) async throws -> TuringQwenBenchmarkResult {
        let startedAt = Date()
        let thermalBefore = thermalState()
        let memoryBefore = MemoryObservation.capture()
        let memorySampler = BenchmarkMemorySampler(initial: memoryBefore)
        let samplerTask = Task {
            await memorySampler.sampleUntilCancelled()
        }
        defer { samplerTask.cancel() }
        let commandBuffers = TuringQwenNativeCommandBufferRunCapture()
        var firstPCMSeconds: Double?
        var generatedRows = 0
        var audioSeconds = 0.0
        var sampleCount = 0
        var sampleRate: Int?
        var reachedEOSSegments = 0
        var rowCapSegments = 0
        var initialPromptSeconds = 0.0
        var decoderSeconds = 0.0
        var samplesAreFinite = true
        var peakAbsoluteSample: Float = 0
        var sampleSquareSum = 0.0
        var audioDigest = TuringQwenBenchmarkDigest.Accumulator()

        for (offset, text) in benchmarkCase.segments.enumerated() {
            let segmentIndex = startingSegmentIndex + offset
            let request = TuringQwenNativeBaseCloneSegmentRequest(
                segmentIndex: segmentIndex,
                text: text,
                language: "english",
                cloneProfile: profile,
                maxNewRows: maxNewRowsPerSegment,
                performanceMode: .performance,
                referenceRowLimit: nil,
                referenceWindowStrategy: .full,
                samplingPolicy: .greedy,
                samplingSeed: samplingSeed &+ UInt64(segmentIndex),
                generationQualityPolicy: .permissive
            )
            let work = TuringQwenNativeGPUWorkIdentity(
                runID: runID,
                segmentIndex: segmentIndex,
                laneIndex: 0,
                instanceID: instance.id.rawValue,
                decodeID: nil
            )
            let lease = try await gpuAdmission.acquireGeneration(work: work)
            await renderPhaseState.renderStarted(
                runID: runID,
                segmentIndex: segmentIndex,
                instanceID: instance.id
            )

            let rendered: TuringQwenRenderedCodebookSegment
            do {
                rendered = try await instance.renderCodebookAndRelease(
                    request,
                    runID: runID,
                    laneIndex: 0,
                    releaseLedger: releaseLedger
                )
                await renderPhaseState.renderReleased(
                    runID: runID,
                    segmentIndex: segmentIndex,
                    instanceID: instance.id
                )
                await gpuAdmission.release(lease, reason: "benchmarkRenderCompleted")
            } catch {
                await renderPhaseState.renderReleased(
                    runID: runID,
                    segmentIndex: segmentIndex,
                    instanceID: instance.id
                )
                await gpuAdmission.release(lease, reason: "benchmarkRenderFailed")
                samplerTask.cancel()
                await samplerTask.value
                throw error
            }

            generatedRows += rendered.generatedRowCount
            reachedEOSSegments += rendered.reachedEOS ? 1 : 0
            if rendered.reachedEOS == false,
               rendered.generatedRowCount >= maxNewRowsPerSegment {
                rowCapSegments += 1
            }
            initialPromptSeconds += rendered.renderMetrics.initialPromptSeconds

            let decoded: TuringQwenDecodedSegment
            do {
                decoded = try await decoder.decode(rendered, token: decoderToken)
            } catch {
                samplerTask.cancel()
                await samplerTask.value
                throw error
            }
            if firstPCMSeconds == nil {
                firstPCMSeconds = Date().timeIntervalSince(startedAt)
            }
            decoderSeconds += decoded.decodeSeconds
            audioSeconds += decoded.audio.durationSeconds
            sampleCount += decoded.audio.samples.count
            if let existingRate = sampleRate, existingRate != decoded.audio.sampleRate {
                samplerTask.cancel()
                await samplerTask.value
                throw TuringQwenNativeError.invalidConfig(
                    "Benchmark decoded inconsistent sample rates."
                )
            }
            sampleRate = decoded.audio.sampleRate
            for sample in decoded.audio.samples {
                samplesAreFinite = samplesAreFinite && sample.isFinite
                peakAbsoluteSample = max(peakAbsoluteSample, abs(sample))
                sampleSquareSum += Double(sample) * Double(sample)
                audioDigest.update(float: sample)
            }
        }

        let totalWallSeconds = Date().timeIntervalSince(startedAt)
        samplerTask.cancel()
        await samplerTask.value
        let sampledMemory = await memorySampler.observation()
        let memoryAfter = MemoryObservation.capture()
        let thermalAfter = thermalState()
        let commandBufferMetrics = commandBuffers.finish(
            profile: .deviceDefault,
            admissionMode: .currentOverlap
        )
        let rms = sampleCount > 0
            ? Float(sqrt(sampleSquareSum / Double(sampleCount)))
            : 0
        let qualityPassed = automatedQualityPassed(
            samplesAreFinite: samplesAreFinite,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            commandBufferFailureCount: commandBufferMetrics.failureCount,
            rowCapSegments: rowCapSegments
        )
        return TuringQwenBenchmarkResult(
            status: qualityPassed ? .passed : .failed,
            input: input(for: benchmarkCase),
            output: TuringQwenBenchmarkOutput(
                generatedRows: .measured(generatedRows),
                audioSeconds: .measured(audioSeconds),
                sampleCount: .measured(sampleCount),
                sampleRate: sampleRate.map { .measured($0) }
                    ?? .unavailable("No decoded audio was produced."),
                audioDigest: .measured(audioDigest.string, detail: "FNV-1a over Float32 bit patterns in segment order."),
                reachedEOSSegments: .measured(reachedEOSSegments),
                rowCapSegments: .measured(rowCapSegments)
            ),
            timing: TuringQwenBenchmarkTiming(
                requestToFirstRowSeconds: unavailableCompletedFirstSemanticRowTiming(),
                requestToFirstPCMSeconds: firstPCMSeconds.map { .measured($0, detail: "Batch decoder returned its first PCM segment.") }
                    ?? .unavailable("No PCM segment was returned."),
                requestToScheduledPlaybackSeconds: .notApplicable("The CLI harness does not schedule playback."),
                requestToAudibleCallbackSeconds: .notApplicable("The CLI harness has no audio-device callback."),
                initialPromptSeconds: .measured(initialPromptSeconds),
                talkerSeconds: unavailableLazyMLXStageTiming(),
                codePredictorSeconds: unavailableLazyMLXStageTiming(),
                tokenMaterializationSeconds: unavailableTokenMaterializationTiming(),
                speechDecoderSeconds: .measured(decoderSeconds),
                totalWallSeconds: .measured(totalWallSeconds),
                audioSecondsPerWallSecond: .measured(
                    totalWallSeconds > 0 ? audioSeconds / totalWallSeconds : 0
                ),
                rowsPerSecond: .measured(
                    totalWallSeconds > 0 ? Double(generatedRows) / totalWallSeconds : 0
                )
            ),
            memory: TuringQwenBenchmarkMemory(
                processFootprintBeforeMB: .measured(memoryBefore.processFootprintMB),
                processFootprintAfterMB: .measured(memoryAfter.processFootprintMB),
                peakProcessFootprintMB: .measured(sampledMemory.peakProcessFootprintMB, detail: "Sampled every 100 ms and at both request boundaries."),
                mlxActiveBeforeMB: .measured(memoryBefore.mlxActiveMB),
                mlxActiveAfterMB: .measured(memoryAfter.mlxActiveMB),
                peakMLXActiveMB: .measured(sampledMemory.peakMLXActiveMB),
                mlxCacheBeforeMB: .measured(memoryBefore.mlxCacheMB),
                mlxCacheAfterMB: .measured(memoryAfter.mlxCacheMB),
                peakMLXCacheMB: .measured(sampledMemory.peakMLXCacheMB)
            ),
            execution: TuringQwenBenchmarkExecution(
                underrunCount: .notApplicable("The CLI harness deliberately performs no playback."),
                synchronizationBarrierCount: unavailableTotalSynchronizationBarrierCount(),
                hostReadbackElementCount: unavailableHostReadbackElementCount(),
                allocationCount: .unavailable("MLX allocation counts are not exposed by the current runtime instrumentation."),
                laneCount: .measured(
                    1,
                    detail: "The benchmark executes serially on one checked-out Fresh instance."
                ),
                laneIdentity: .measured(instance.id.rawValue, detail: "A single fixed Fresh2 lane is held for deterministic comparisons."),
                streamIdentity: .measured(TuringQwenNativeLaneStreamMode.defaultOnly.rawValue),
                commandBuffersSubmitted: .measured(commandBufferMetrics.submittedCount),
                commandBuffersCompleted: .measured(commandBufferMetrics.completedCount),
                commandBufferFailures: .measured(commandBufferMetrics.failureCount)
            ),
            quality: TuringQwenBenchmarkQuality(
                passed: qualityPassed,
                decodedSegmentCount: benchmarkCase.segments.count,
                expectedSegmentCount: benchmarkCase.segments.count,
                samplesAreFinite: .measured(samplesAreFinite),
                nonEmptyAudio: .measured(sampleCount > 0),
                peakAbsoluteSample: .measured(peakAbsoluteSample),
                rms: .measured(rms),
                perceptualAssessment: .unavailable("Human or reference-model listening assessment is intentionally not fabricated by the CLI.")
            ),
            thermal: TuringQwenBenchmarkThermal(
                stateBefore: .measured(thermalBefore),
                stateAfter: .measured(thermalAfter)
            ),
            error: qualityPassed
                ? nil
                : "Automated audio, sample-rate, row-cap, or command-buffer quality gate failed."
        )
    }

    static func automatedQualityPassed(
        samplesAreFinite: Bool,
        sampleCount: Int,
        sampleRate: Int?,
        commandBufferFailureCount: Int,
        rowCapSegments: Int
    ) -> Bool {
        samplesAreFinite
            && sampleCount > 0
            && sampleRate == 24_000
            && commandBufferFailureCount == 0
            && rowCapSegments == 0
    }

    private static func lockedProfile(
        from profile: TuringQwenNativeCloneProfile
    ) -> TuringQwenNativeCloneProfile {
        TuringQwenNativeCloneProfile(
            voiceID: profile.voiceID,
            speakerID: profile.speakerID,
            modelID: profile.modelID,
            profileKind: profile.profileKind,
            rootURL: profile.rootURL,
            referenceAudioURL: profile.referenceAudioURL,
            originalReferenceAudioURL: profile.originalReferenceAudioURL,
            referenceText: profile.referenceText,
            defaultVariantID: variantID,
            allowFallback: false,
            variants: profile.variants
        )
    }

    private static func input(
        for benchmarkCase: TuringQwenBenchmarkCase
    ) -> TuringQwenBenchmarkInput {
        TuringQwenBenchmarkInput(
            id: benchmarkCase.id,
            tier: benchmarkCase.tier,
            text: benchmarkCase.text,
            textDigest: benchmarkCase.digest,
            characterCount: benchmarkCase.text.utf16.count,
            wordCount: benchmarkCase.wordCount,
            segments: benchmarkCase.segments
        )
    }

    private static func failedResult(
        for benchmarkCase: TuringQwenBenchmarkCase,
        error: Error?,
        skipped: Bool = false
    ) -> TuringQwenBenchmarkResult {
        let reason = skipped
            ? "Skipped after an earlier setup, warmup, or inference failure."
            : (error?.localizedDescription ?? "Unknown benchmark failure.")
        return TuringQwenBenchmarkResult(
            status: skipped ? .skipped : .failed,
            input: input(for: benchmarkCase),
            output: TuringQwenBenchmarkOutput(
                generatedRows: .unavailable(reason),
                audioSeconds: .unavailable(reason),
                sampleCount: .unavailable(reason),
                sampleRate: .unavailable(reason),
                audioDigest: .unavailable(reason),
                reachedEOSSegments: .unavailable(reason),
                rowCapSegments: .unavailable(reason)
            ),
            timing: TuringQwenBenchmarkTiming(
                requestToFirstRowSeconds: .unavailable(reason),
                requestToFirstPCMSeconds: .unavailable(reason),
                requestToScheduledPlaybackSeconds: .notApplicable("The CLI harness does not schedule playback."),
                requestToAudibleCallbackSeconds: .notApplicable("The CLI harness has no audio-device callback."),
                initialPromptSeconds: .unavailable(reason),
                talkerSeconds: .unavailable(reason),
                codePredictorSeconds: .unavailable(reason),
                tokenMaterializationSeconds: .unavailable(reason),
                speechDecoderSeconds: .unavailable(reason),
                totalWallSeconds: .unavailable(reason),
                audioSecondsPerWallSecond: .unavailable(reason),
                rowsPerSecond: .unavailable(reason)
            ),
            memory: TuringQwenBenchmarkMemory(
                processFootprintBeforeMB: .unavailable(reason),
                processFootprintAfterMB: .unavailable(reason),
                peakProcessFootprintMB: .unavailable(reason),
                mlxActiveBeforeMB: .unavailable(reason),
                mlxActiveAfterMB: .unavailable(reason),
                peakMLXActiveMB: .unavailable(reason),
                mlxCacheBeforeMB: .unavailable(reason),
                mlxCacheAfterMB: .unavailable(reason),
                peakMLXCacheMB: .unavailable(reason)
            ),
            execution: TuringQwenBenchmarkExecution(
                underrunCount: .notApplicable("The CLI harness deliberately performs no playback."),
                synchronizationBarrierCount: .unavailable(reason),
                hostReadbackElementCount: .unavailable(reason),
                allocationCount: .unavailable(reason),
                laneCount: .unavailable(reason),
                laneIdentity: .unavailable(reason),
                streamIdentity: .unavailable(reason),
                commandBuffersSubmitted: .unavailable(reason),
                commandBuffersCompleted: .unavailable(reason),
                commandBufferFailures: .unavailable(reason)
            ),
            quality: TuringQwenBenchmarkQuality(
                passed: false,
                decodedSegmentCount: 0,
                expectedSegmentCount: benchmarkCase.segments.count,
                samplesAreFinite: .unavailable(reason),
                nonEmptyAudio: .unavailable(reason),
                peakAbsoluteSample: .unavailable(reason),
                rms: .unavailable(reason),
                perceptualAssessment: .unavailable(reason)
            ),
            thermal: TuringQwenBenchmarkThermal(
                stateBefore: .unavailable(reason),
                stateAfter: .unavailable(reason)
            ),
            error: reason
        )
    }

    private static func aggregate(
        _ results: [TuringQwenBenchmarkResult]
    ) -> TuringQwenBenchmarkAggregate {
        let passed = results.filter { $0.status == .passed }
        let generatedRows = passed.compactMap(\.output.generatedRows.value).reduce(0, +)
        let audioSeconds = passed.compactMap(\.output.audioSeconds.value).reduce(0, +)
        let wallSeconds = passed.compactMap(\.timing.totalWallSeconds.value).reduce(0, +)
        let processPeak = passed.compactMap(\.memory.peakProcessFootprintMB.value).max()
        let activePeak = passed.compactMap(\.memory.peakMLXActiveMB.value).max()
        let cachePeak = passed.compactMap(\.memory.peakMLXCacheMB.value).max()
        let commandFailures = passed.compactMap(\.execution.commandBufferFailures.value).reduce(0, +)
        let hasMeasurements = passed.isEmpty == false
        let unavailable = "No selected corpus case completed successfully."
        return TuringQwenBenchmarkAggregate(
            caseCount: results.count,
            passedCaseCount: passed.count,
            failedCaseCount: results.count - passed.count,
            segmentCount: passed.reduce(0) { $0 + $1.input.segments.count },
            generatedRows: hasMeasurements ? .measured(generatedRows) : .unavailable(unavailable),
            audioSeconds: hasMeasurements ? .measured(audioSeconds) : .unavailable(unavailable),
            totalWallSeconds: hasMeasurements ? .measured(wallSeconds) : .unavailable(unavailable),
            audioSecondsPerWallSecond: hasMeasurements
                ? .measured(wallSeconds > 0 ? audioSeconds / wallSeconds : 0)
                : .unavailable(unavailable),
            rowsPerSecond: hasMeasurements
                ? .measured(wallSeconds > 0 ? Double(generatedRows) / wallSeconds : 0)
                : .unavailable(unavailable),
            synchronizationBarrierCount: unavailableTotalSynchronizationBarrierCount(),
            hostReadbackElementCount: unavailableHostReadbackElementCount(),
            tokenMaterializationSeconds: unavailableTokenMaterializationTiming(),
            peakProcessFootprintMB: processPeak.map { .measured($0) }
                ?? .unavailable(unavailable),
            peakMLXActiveMB: activePeak.map { .measured($0) }
                ?? .unavailable(unavailable),
            peakMLXCacheMB: cachePeak.map { .measured($0) }
                ?? .unavailable(unavailable),
            commandBufferFailures: hasMeasurements
                ? .measured(commandFailures)
                : .unavailable(unavailable)
        )
    }

    private static func comparison(
        baseline: TuringQwenOptimizationBenchmarkReport?,
        currentLabel: String,
        currentAggregate: TuringQwenBenchmarkAggregate,
        currentResults: [TuringQwenBenchmarkResult],
        currentModel: TuringQwenBenchmarkModelIdentity,
        currentDevice: TuringQwenBenchmarkDeviceIdentity,
        currentBuild: TuringQwenBenchmarkBuildIdentity,
        currentConfiguration: TuringQwenBenchmarkConfiguration
    ) -> TuringQwenBenchmarkComparison {
        let metricValues: [(String, Double?)] = [
            ("totalWallSeconds", currentAggregate.totalWallSeconds.value),
            ("audioSecondsPerWallSecond", currentAggregate.audioSecondsPerWallSecond.value),
            ("rowsPerSecond", currentAggregate.rowsPerSecond.value),
            ("synchronizationBarrierCount", currentAggregate.synchronizationBarrierCount.value.map(Double.init)),
            ("hostReadbackElementCount", currentAggregate.hostReadbackElementCount.value.map(Double.init)),
            ("tokenMaterializationSeconds", currentAggregate.tokenMaterializationSeconds.value),
            ("peakProcessFootprintMB", currentAggregate.peakProcessFootprintMB.value),
            ("peakMLXActiveMB", currentAggregate.peakMLXActiveMB.value),
            ("peakMLXCacheMB", currentAggregate.peakMLXCacheMB.value)
        ]
        guard let baseline else {
            return TuringQwenBenchmarkComparison(
                status: "baselineNotProvided",
                baselineLabel: .unavailable("Pass --baseline to compute before/after deltas."),
                metrics: metricValues.map { name, after in
                    unavailableDelta(metric: name, after: after)
                },
                matchingCaseCount: .unavailable("No baseline report was provided."),
                exactAudioDigestMatchCount: .unavailable("No baseline report was provided."),
                qualityRegressions: []
            )
        }
        let incompatibilities = baselineCompatibilityFailures(
            baseline: baseline,
            currentModel: currentModel,
            currentDevice: currentDevice,
            currentBuild: currentBuild,
            currentConfiguration: currentConfiguration,
            currentResults: currentResults
        )
        guard incompatibilities.isEmpty else {
            let reason = "Baseline is incompatible with \(currentLabel): " +
                incompatibilities.joined(separator: "; ")
            return TuringQwenBenchmarkComparison(
                status: "incompatibleBaseline",
                baselineLabel: .measured(baseline.label),
                metrics: metricValues.map { name, after in
                    unavailableDelta(
                        metric: name,
                        after: after,
                        reason: reason
                    )
                },
                matchingCaseCount: .unavailable(reason),
                exactAudioDigestMatchCount: .unavailable(reason),
                qualityRegressions: incompatibilities
            )
        }

        let baselineValues: [String: Double?] = [
            "totalWallSeconds": baseline.aggregate.totalWallSeconds.value,
            "audioSecondsPerWallSecond": baseline.aggregate.audioSecondsPerWallSecond.value,
            "rowsPerSecond": baseline.aggregate.rowsPerSecond.value,
            "synchronizationBarrierCount": baseline.aggregate.synchronizationBarrierCount.value.map(Double.init),
            "hostReadbackElementCount": baseline.aggregate.hostReadbackElementCount.value.map(Double.init),
            "tokenMaterializationSeconds": baseline.aggregate.tokenMaterializationSeconds.value,
            "peakProcessFootprintMB": baseline.aggregate.peakProcessFootprintMB.value,
            "peakMLXActiveMB": baseline.aggregate.peakMLXActiveMB.value,
            "peakMLXCacheMB": baseline.aggregate.peakMLXCacheMB.value
        ]
        let deltas = metricValues.map { name, after in
            metricDelta(metric: name, before: baselineValues[name] ?? nil, after: after)
        }
        let beforeByID = Dictionary(uniqueKeysWithValues: baseline.results.map { ($0.input.id, $0) })
        let pairs = currentResults.compactMap { current -> (TuringQwenBenchmarkResult, TuringQwenBenchmarkResult)? in
            guard let before = beforeByID[current.input.id] else { return nil }
            return (before, current)
        }
        let exactMatches = pairs.filter { before, after in
            guard let beforeDigest = before.output.audioDigest.value,
                  let afterDigest = after.output.audioDigest.value else { return false }
            return beforeDigest == afterDigest
        }.count
        let regressions = pairs.flatMap { before, after in
            acceptanceRegressions(
                caseID: after.input.id,
                baselineStatus: before.status,
                currentStatus: after.status,
                baselineQualityPassed: before.quality.passed,
                currentQualityPassed: after.quality.passed,
                baselineAudioDigest: before.output.audioDigest.value,
                currentAudioDigest: after.output.audioDigest.value
            )
        }
        return TuringQwenBenchmarkComparison(
            status: "compared",
            baselineLabel: .measured(baseline.label),
            metrics: deltas,
            matchingCaseCount: .measured(pairs.count),
            exactAudioDigestMatchCount: .measured(exactMatches),
            qualityRegressions: regressions
        )
    }

    static func baselineCompatibilityFailures(
        baseline: TuringQwenOptimizationBenchmarkReport,
        currentModel: TuringQwenBenchmarkModelIdentity,
        currentDevice: TuringQwenBenchmarkDeviceIdentity,
        currentBuild: TuringQwenBenchmarkBuildIdentity,
        currentConfiguration: TuringQwenBenchmarkConfiguration,
        currentResults: [TuringQwenBenchmarkResult]
    ) -> [String] {
        var failures: [String] = []

        appendMismatch(
            field: "schemaVersion",
            baseline: baseline.schemaVersion,
            current: 2,
            failures: &failures
        )

        appendMismatch(
            field: "model.modelID",
            baseline: baseline.model.modelID,
            current: currentModel.modelID,
            failures: &failures
        )
        appendMismatch(
            field: "model.ttsModelType",
            baseline: baseline.model.ttsModelType,
            current: currentModel.ttsModelType,
            failures: &failures
        )
        appendMeasurementMismatch(
            field: "model.quantizationBits",
            baseline: baseline.model.quantizationBits,
            current: currentModel.quantizationBits,
            failures: &failures
        )
        appendMeasurementMismatch(
            field: "model.quantizationGroupSize",
            baseline: baseline.model.quantizationGroupSize,
            current: currentModel.quantizationGroupSize,
            failures: &failures
        )
        appendMismatch(
            field: "model.cloneVoiceID",
            baseline: baseline.model.cloneVoiceID,
            current: currentModel.cloneVoiceID,
            failures: &failures
        )
        appendMismatch(
            field: "model.cloneVariantID",
            baseline: baseline.model.cloneVariantID,
            current: currentModel.cloneVariantID,
            failures: &failures
        )
        appendMeasurementMismatch(
            field: "model.cloneRevision",
            baseline: baseline.model.cloneRevision,
            current: currentModel.cloneRevision,
            failures: &failures
        )

        // `ProcessInfo.hostName` can alternate between the local Bonjour name and
        // reverse-DNS aliases on the same Mac. Keep it in the report for diagnostics,
        // but use the stable hardware and OS fields below for device compatibility.
        appendMismatch(
            field: "device.operatingSystem",
            baseline: baseline.device.operatingSystem,
            current: currentDevice.operatingSystem,
            failures: &failures
        )
        appendMismatch(
            field: "device.architecture",
            baseline: baseline.device.architecture,
            current: currentDevice.architecture,
            failures: &failures
        )
        appendMismatch(
            field: "device.physicalMemoryBytes",
            baseline: baseline.device.physicalMemoryBytes,
            current: currentDevice.physicalMemoryBytes,
            failures: &failures
        )
        appendMeasurementMismatch(
            field: "device.metalDevice",
            baseline: baseline.device.metalDevice,
            current: currentDevice.metalDevice,
            failures: &failures
        )

        appendMismatch(
            field: "build.configuration",
            baseline: baseline.build.configuration,
            current: currentBuild.configuration,
            failures: &failures
        )
        appendMismatch(
            field: "build.commandBufferProfile",
            baseline: baseline.build.commandBufferProfile,
            current: currentBuild.commandBufferProfile,
            failures: &failures
        )
        appendMeasurementMismatch(
            field: "build.executableProduct",
            baseline: executableProduct(baseline.build.executable),
            current: executableProduct(currentBuild.executable),
            failures: &failures
        )

        appendMismatch(
            field: "configuration.suite",
            baseline: baseline.configuration.suite,
            current: currentConfiguration.suite,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.corpusDigest",
            baseline: baseline.configuration.corpusDigest,
            current: currentConfiguration.corpusDigest,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.warmupText",
            baseline: baseline.configuration.warmupText,
            current: currentConfiguration.warmupText,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.warmupCount",
            baseline: baseline.configuration.warmupCount,
            current: currentConfiguration.warmupCount,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.language",
            baseline: baseline.configuration.language,
            current: currentConfiguration.language,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.maxNewRowsPerSegment",
            baseline: baseline.configuration.maxNewRowsPerSegment,
            current: currentConfiguration.maxNewRowsPerSegment,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.referenceWindowStrategy",
            baseline: baseline.configuration.referenceWindowStrategy,
            current: currentConfiguration.referenceWindowStrategy,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.samplingPolicy",
            baseline: baseline.configuration.samplingPolicy,
            current: currentConfiguration.samplingPolicy,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.samplingSeed",
            baseline: baseline.configuration.samplingSeed,
            current: currentConfiguration.samplingSeed,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.performanceMode",
            baseline: baseline.configuration.performanceMode,
            current: currentConfiguration.performanceMode,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.playbackRate",
            baseline: baseline.configuration.playbackRate,
            current: currentConfiguration.playbackRate,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.playbackRateApplied",
            baseline: baseline.configuration.playbackRateApplied,
            current: currentConfiguration.playbackRateApplied,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.residencyMode",
            baseline: baseline.configuration.residencyMode,
            current: currentConfiguration.residencyMode,
            failures: &failures
        )
        appendMismatch(
            field: "configuration.benchmarkLanePolicy",
            baseline: baseline.configuration.benchmarkLanePolicy,
            current: currentConfiguration.benchmarkLanePolicy,
            failures: &failures
        )

        let baselineIDs = baseline.results.map(\.input.id)
        let currentIDs = currentResults.map(\.input.id)
        if Set(baselineIDs).count != baselineIDs.count {
            failures.append("baseline case set contains duplicate identifiers")
        }
        if Set(currentIDs).count != currentIDs.count {
            failures.append("current case set contains duplicate identifiers")
        }
        if baselineIDs.count != currentIDs.count || Set(baselineIDs) != Set(currentIDs) {
            failures.append("case identifier set differs")
        } else if Set(baselineIDs).count == baselineIDs.count,
                  Set(currentIDs).count == currentIDs.count {
            let baselineByID = Dictionary(
                uniqueKeysWithValues: baseline.results.map { ($0.input.id, $0.input) }
            )
            for current in currentResults {
                guard let prior = baselineByID[current.input.id] else { continue }
                if prior.tier != current.input.tier ||
                    prior.textDigest != current.input.textDigest ||
                    prior.segments != current.input.segments {
                    failures.append("case payload differs for \(current.input.id)")
                }
            }
        }

        return failures
    }

    private static func appendMismatch<Value: Equatable>(
        field: String,
        baseline: Value,
        current: Value,
        failures: inout [String]
    ) {
        guard baseline != current else { return }
        failures.append("\(field) differs")
    }

    private static func appendMeasurementMismatch<Value>(
        field: String,
        baseline: TuringQwenBenchmarkMeasurement<Value>,
        current: TuringQwenBenchmarkMeasurement<Value>,
        failures: inout [String]
    ) where Value: Codable & Sendable & Equatable {
        guard baseline.status == .measured,
              current.status == .measured,
              let baselineValue = baseline.value,
              let currentValue = current.value,
              baselineValue == currentValue else {
            failures.append("\(field) differs or is unavailable in one run")
            return
        }
    }

    private static func executableProduct(
        _ measurement: TuringQwenBenchmarkMeasurement<String>
    ) -> TuringQwenBenchmarkMeasurement<String> {
        guard let path = measurement.value else {
            return TuringQwenBenchmarkMeasurement(
                status: measurement.status,
                value: nil,
                detail: measurement.detail
            )
        }
        return TuringQwenBenchmarkMeasurement(
            status: measurement.status,
            value: URL(fileURLWithPath: path).lastPathComponent,
            detail: measurement.detail
        )
    }

    static func acceptanceRegressions(
        caseID: String,
        baselineStatus: TuringQwenBenchmarkRunStatus,
        currentStatus: TuringQwenBenchmarkRunStatus,
        baselineQualityPassed: Bool,
        currentQualityPassed: Bool,
        baselineAudioDigest: String?,
        currentAudioDigest: String?
    ) -> [String] {
        var regressions: [String] = []
        if baselineStatus == .passed, currentStatus != .passed {
            regressions.append(
                "\(caseID) passed the baseline run but the current status is \(currentStatus.rawValue)."
            )
        } else if baselineQualityPassed, !currentQualityPassed {
            regressions.append(
                "\(caseID) passed baseline quality checks but failed the current run."
            )
        }

        if let baselineAudioDigest,
           let currentAudioDigest,
           baselineAudioDigest != currentAudioDigest {
            regressions.append(
                "\(caseID) PCM digest changed from \(baselineAudioDigest) to \(currentAudioDigest)."
            )
        }
        return regressions
    }

    static func comparisonFailureReasons(
        _ comparison: TuringQwenBenchmarkComparison
    ) -> [String] {
        comparison.qualityRegressions.map {
            "Benchmark comparison acceptance regression: \($0)"
        }
    }

    static func comparisonAcceptanceFailureReasons(
        _ comparison: TuringQwenBenchmarkComparison
    ) -> [String] {
        var reasons = comparisonFailureReasons(comparison)
        guard comparison.status == "compared" else {
            return reasons
        }

        if comparison.matchingCaseCount.status != .measured ||
            comparison.exactAudioDigestMatchCount.status != .measured ||
            comparison.matchingCaseCount.value == nil ||
            comparison.exactAudioDigestMatchCount.value == nil {
            reasons.append(
                "Benchmark PCM acceptance could not be evaluated because exact digest counts are unavailable."
            )
        } else if let matchingCaseCount = comparison.matchingCaseCount.value,
                  let exactMatchCount = comparison.exactAudioDigestMatchCount.value,
                  matchingCaseCount == 0 || exactMatchCount != matchingCaseCount {
            reasons.append(
                "Benchmark PCM acceptance failed: \(exactMatchCount) of " +
                    "\(matchingCaseCount) matching case(s) had exact PCM digests."
            )
        }

        guard let throughput = comparison.metrics.first(where: {
            $0.metric == "audioSecondsPerWallSecond"
        }),
            throughput.before.status == .measured,
            throughput.after.status == .measured,
            let before = throughput.before.value,
            let after = throughput.after.value,
            before > 0 else {
            reasons.append(
                "Benchmark aggregate warm-throughput acceptance could not be evaluated: " +
                    "a compatible " +
                    "comparison requires positive measured before/after aggregate " +
                    "audioSecondsPerWallSecond values."
            )
            return reasons
        }

        let gainPercent = ((after - before) / before) * 100
        if gainPercent < minimumThroughputGainPercent {
            reasons.append(
                "Benchmark aggregate warm-throughput acceptance failed: aggregate " +
                    "audioSecondsPerWallSecond improved by \(format(gainPercent))%; " +
                    "required >=\(format(minimumThroughputGainPercent))%."
            )
        }
        return reasons
    }

    private static func completionSuccessReason(
        comparison: TuringQwenBenchmarkComparison
    ) -> String {
        if comparison.status == "compared" {
            return "All selected deterministic corpus cases passed with exact PCM " +
                "digests and at least \(format(minimumThroughputGainPercent))% aggregate " +
                "warm-throughput improvement."
        }
        return "All selected deterministic corpus cases passed."
    }

    private static func metricDelta(
        metric: String,
        before: Double?,
        after: Double?
    ) -> TuringQwenBenchmarkMetricDelta {
        let missing = "Metric was unavailable in one or both reports."
        guard let before, let after else {
            return TuringQwenBenchmarkMetricDelta(
                metric: metric,
                before: before.map { .measured($0) } ?? .unavailable(missing),
                after: after.map { .measured($0) } ?? .unavailable(missing),
                delta: .unavailable(missing),
                deltaPercent: .unavailable(missing)
            )
        }
        return TuringQwenBenchmarkMetricDelta(
            metric: metric,
            before: .measured(before),
            after: .measured(after),
            delta: .measured(after - before),
            deltaPercent: before != 0
                ? .measured(((after - before) / before) * 100)
                : .unavailable("A zero baseline cannot produce a percentage delta.")
        )
    }

    private static func unavailableDelta(
        metric: String,
        after: Double?,
        reason: String = "No baseline report was provided."
    ) -> TuringQwenBenchmarkMetricDelta {
        TuringQwenBenchmarkMetricDelta(
            metric: metric,
            before: .unavailable(reason),
            after: after.map { .measured($0) } ?? .unavailable("Current metric is unavailable."),
            delta: .unavailable(reason),
            deltaPercent: .unavailable(reason)
        )
    }

    private static func benchmarkConfiguration(
        suite: TuringQwenBenchmarkSuite
    ) -> TuringQwenBenchmarkConfiguration {
        TuringQwenBenchmarkConfiguration(
            suite: suite,
            corpusDigest: TuringQwenOptimizationBenchmarkCorpus.digest,
            warmupText: warmupText,
            warmupCount: 1,
            language: "english",
            maxNewRowsPerSegment: maxNewRowsPerSegment,
            referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy.full.rawValue,
            samplingPolicy: "greedyTalker+greedyCodePredictor",
            samplingSeed: samplingSeed,
            performanceMode: TuringQwenNativePerformanceMode.performance.rawValue,
            playbackRate: 0.85,
            playbackRateApplied: false,
            residencyMode: TuringQwenNativeResidencyMode.sharedImmutableFresh2.rawValue,
            benchmarkLanePolicy: "one fixed Fresh2 lane; serial segments; default stream"
        )
    }

    private static func modelIdentity(
        modelRoot: URL,
        profile: TuringQwenNativeCloneProfile,
        config: TuringQwenNativeConfig
    ) -> TuringQwenBenchmarkModelIdentity {
        let revision = cloneRevision(profileRoot: profile.rootURL)
        return TuringQwenBenchmarkModelIdentity(
            modelID: profile.modelID,
            modelRoot: modelRoot.standardizedFileURL.path,
            ttsModelType: config.ttsModelType,
            quantizationBits: config.quantization.map { .measured($0.bits) }
                ?? .unavailable("Model config has no quantization block."),
            quantizationGroupSize: config.quantization.map { .measured($0.groupSize) }
                ?? .unavailable("Model config has no quantization block."),
            cloneVoiceID: profile.voiceID,
            cloneVariantID: variantID,
            cloneRevision: revision.map { .measured($0) }
                ?? .unavailable("Clone metadata contains no revision.")
        )
    }

    private static func unavailableModelIdentity(
        modelRoot: URL
    ) -> TuringQwenBenchmarkModelIdentity {
        let reason = "Model identity could not be validated during setup."
        return TuringQwenBenchmarkModelIdentity(
            modelID: "qwen3-tts-12hz-1.7b-base-4bit",
            modelRoot: modelRoot.standardizedFileURL.path,
            ttsModelType: "base",
            quantizationBits: .unavailable(reason),
            quantizationGroupSize: .unavailable(reason),
            cloneVoiceID: voiceID,
            cloneVariantID: variantID,
            cloneRevision: .unavailable(reason)
        )
    }

    private static func cloneRevision(profileRoot: URL) -> String? {
        struct Metadata: Decodable { let revision: String? }
        let url = profileRoot.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        return metadata.revision
    }

    private static func deviceIdentity() -> TuringQwenBenchmarkDeviceIdentity {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        #if canImport(Metal)
        let metalDevice = MTLCreateSystemDefaultDevice()?.name
        #else
        let metalDevice: String? = nil
        #endif
        return TuringQwenBenchmarkDeviceIdentity(
            hostName: ProcessInfo.processInfo.hostName,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            metalDevice: metalDevice.map { .measured($0) }
                ?? .unavailable("No default Metal device is available.")
        )
    }

    private static func buildIdentity(
        gitRevision: String?,
        executable: String?,
        repositoryStartURL: URL
    ) -> TuringQwenBenchmarkBuildIdentity {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let workingTree = workingTreeProvenance(startingAt: repositoryStartURL)
        let revision: TuringQwenBenchmarkMeasurement<String>
        if let gitRevision {
            revision = .measured(gitRevision, detail: workingTree)
        } else {
            revision = .unavailable(
                "No git revision was supplied or discovered. \(workingTree)"
            )
        }
        return TuringQwenBenchmarkBuildIdentity(
            configuration: configuration,
            gitRevision: revision,
            executable: executable.map { .measured($0) }
                ?? .unavailable("Executable path is unavailable."),
            commandBufferProfile: TuringQwenNativeCommandBufferProfile.deviceDefault.rawValue
        )
    }

    private static func workingTreeProvenance(startingAt url: URL) -> String {
        #if os(macOS)
        var candidate = url.standardizedFileURL
        var repositoryRoot: URL?
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) {
                repositoryRoot = candidate
                break
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        guard let repositoryRoot else {
            return "workingTree=unavailable; no enclosing Git repository"
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C",
            repositoryRoot.path,
            "status",
            "--porcelain",
            "--untracked-files=normal"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "workingTree=unavailable; git status exited \(process.terminationStatus)"
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let status = String(data: data, encoding: .utf8) ?? ""
            let changedPathCount = status.split(whereSeparator: \.isNewline).count
            return changedPathCount == 0
                ? "workingTree=clean"
                : "workingTree=dirty; changedPathCount=\(changedPathCount)"
        } catch {
            return "workingTree=unavailable; git status could not run"
        }
        #else
        return "workingTree=unavailable; Git process inspection is host-only"
        #endif
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct MemoryObservation: Sendable {
    let processFootprintMB: Double
    let mlxActiveMB: Double
    let mlxCacheMB: Double

    static func capture() -> Self {
        let process = TuringQwenNativeProcessMemoryProbe.snapshot()
        let mlx = Memory.snapshot()
        let divisor = 1024.0 * 1024.0
        return Self(
            processFootprintMB: process.physFootprintMB,
            mlxActiveMB: Double(mlx.activeMemory) / divisor,
            mlxCacheMB: Double(mlx.cacheMemory) / divisor
        )
    }
}

private actor BenchmarkMemorySampler {
    private var peakProcessFootprintMB: Double
    private var peakMLXActiveMB: Double
    private var peakMLXCacheMB: Double

    init(initial: MemoryObservation) {
        peakProcessFootprintMB = initial.processFootprintMB
        peakMLXActiveMB = initial.mlxActiveMB
        peakMLXCacheMB = initial.mlxCacheMB
    }

    func sampleUntilCancelled() async {
        while Task.isCancelled == false {
            record(MemoryObservation.capture())
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        record(MemoryObservation.capture())
    }

    func observation() -> SampledMemoryObservation {
        SampledMemoryObservation(
            peakProcessFootprintMB: peakProcessFootprintMB,
            peakMLXActiveMB: peakMLXActiveMB,
            peakMLXCacheMB: peakMLXCacheMB
        )
    }

    private func record(_ observation: MemoryObservation) {
        peakProcessFootprintMB = max(
            peakProcessFootprintMB,
            observation.processFootprintMB
        )
        peakMLXActiveMB = max(peakMLXActiveMB, observation.mlxActiveMB)
        peakMLXCacheMB = max(peakMLXCacheMB, observation.mlxCacheMB)
    }
}

private struct SampledMemoryObservation: Sendable {
    let peakProcessFootprintMB: Double
    let peakMLXActiveMB: Double
    let peakMLXCacheMB: Double
}
