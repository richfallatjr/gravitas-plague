import Foundation
import Testing
@testable import TuringQwenNative

@Suite(.serialized)
struct TuringQwenOptimizationBenchmarkTests {
    @Test
    func lockedFullCorpusHasRequiredTierCountsAndStableIdentifiers() {
        let corpus = TuringQwenOptimizationBenchmarkCorpus.full
        #expect(corpus.count == 33)
        #expect(corpus.filter { $0.tier == .short }.count == 10)
        #expect(corpus.filter { $0.tier == .medium }.count == 10)
        #expect(corpus.filter { $0.tier == .long }.count == 10)
        #expect(corpus.filter { $0.tier == .multiMinute }.count == 3)
        #expect(Set(corpus.map(\.id)).count == corpus.count)
        #expect(corpus.allSatisfy { !$0.segments.isEmpty })
        #expect(corpus.allSatisfy { $0.segments.allSatisfy { !$0.isEmpty } })
        #expect(corpus.filter { $0.tier == .multiMinute }.allSatisfy { $0.wordCount >= 500 })
        #expect(TuringQwenOptimizationBenchmarkCorpus.digest.count == 16)
        #expect(
            TuringQwenOptimizationBenchmarkCorpus.digest
                == TuringQwenOptimizationBenchmarkCorpus.digest
        )
    }

    @Test
    func quickCorpusIsDeterministicSubsetWithoutMultiMinuteRuntime() {
        let quick = TuringQwenOptimizationBenchmarkCorpus.quick
        #expect(quick.map(\.id) == ["short-01", "medium-01", "long-01"])
        #expect(quick.allSatisfy { $0.tier != .multiMinute })
    }

    @Test
    func longAndMultiMinuteScriptsUseSentenceSizedSegments() {
        let longCases = TuringQwenOptimizationBenchmarkCorpus.full.filter {
            $0.tier == .long
        }
        let multiMinuteCases = TuringQwenOptimizationBenchmarkCorpus.full.filter {
            $0.tier == .multiMinute
        }
        let segmentedCases = longCases + multiMinuteCases

        #expect(longCases.allSatisfy { $0.segments.count == 6 })
        #expect(multiMinuteCases.allSatisfy { $0.segments.count == 61 })
        #expect(
            segmentedCases.allSatisfy { benchmarkCase in
                benchmarkCase.segments.allSatisfy { segment in
                    segment.split(whereSeparator: \.isWhitespace).count <= 30
                }
            }
        )
    }

    @Test
    func unavailableMeasurementWritesExplicitJSONNull() throws {
        let measurement = TuringQwenBenchmarkMeasurement<Double>.unavailable(
            "counter not exposed"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(measurement))
                as? [String: Any]
        )
        #expect(object["status"] as? String == "unavailable")
        #expect(object.keys.contains("value"))
        #expect(object["value"] is NSNull)
    }

    @Test
    func lazyMLXStageTimingsAreExplicitlyUnavailable() {
        let measurement = TuringQwenOptimizationBenchmarkRunner
            .unavailableLazyMLXStageTiming()

        #expect(measurement.status == .unavailable)
        #expect(measurement.value == nil)
        #expect(measurement.detail?.contains("lazy MLX") == true)
        #expect(measurement.detail?.contains("completed GPU execution") == true)
    }

    @Test
    func lazyFirstRowTimestampIsNotReportedAsCompletedExecution() {
        let measurement = TuringQwenOptimizationBenchmarkRunner
            .unavailableCompletedFirstSemanticRowTiming()

        #expect(measurement.status == .unavailable)
        #expect(measurement.value == nil)
        #expect(measurement.detail?.contains("lazy graph") == true)
        #expect(measurement.detail?.contains("completion-observed") == true)
        #expect(measurement.detail?.contains("completed MLX execution") == true)
    }

    @Test
    func partialSynchronizationCounterIsNotReportedAsTotal() {
        let measurement = TuringQwenOptimizationBenchmarkRunner
            .unavailableTotalSynchronizationBarrierCount()

        #expect(measurement.status == .unavailable)
        #expect(measurement.value == nil)
        #expect(measurement.detail?.contains("baseline runtime") == true)
        #expect(measurement.detail?.contains("complete count") == true)
    }

    @Test
    func revertedRuntimeOnlyReportsSupportedTokenAndReadbackMeasurements() {
        let tokenTiming = TuringQwenOptimizationBenchmarkRunner
            .unavailableTokenMaterializationTiming()
        let hostReadbacks = TuringQwenOptimizationBenchmarkRunner
            .unavailableHostReadbackElementCount()

        #expect(tokenTiming.status == .unavailable)
        #expect(tokenTiming.value == nil)
        #expect(tokenTiming.detail?.contains("baseline runtime") == true)
        #expect(tokenTiming.detail?.contains("isolated") == true)
        #expect(hostReadbacks.status == .unavailable)
        #expect(hostReadbacks.value == nil)
        #expect(hostReadbacks.detail?.contains("baseline runtime") == true)
        #expect(hostReadbacks.detail?.contains("complete") == true)
    }

    @Test
    func executionReportWritesNumericLaneCount() throws {
        let execution = benchmarkExecutionFixture()
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(execution))
                as? [String: Any]
        )
        let laneCount = try #require(object["laneCount"] as? [String: Any])

        #expect(laneCount["status"] as? String == "measured")
        #expect((laneCount["value"] as? NSNumber)?.intValue == 1)
    }

    @Test
    func executionWithoutLaneCountDecodesAsUnavailableAndReencodesField() throws {
        let encoded = try JSONEncoder().encode(benchmarkExecutionFixture())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "laneCount")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            TuringQwenBenchmarkExecution.self,
            from: legacyData
        )
        #expect(decoded.laneCount.status == .unavailable)
        #expect(decoded.laneCount.value == nil)
        #expect(decoded.laneCount.detail?.contains("predates") == true)

        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
                as? [String: Any]
        )
        #expect(reencoded["laneCount"] is [String: Any])
    }

    @Test
    func anyRowCapHitFailsAutomatedQuality() {
        #expect(
            TuringQwenOptimizationBenchmarkRunner.automatedQualityPassed(
                samplesAreFinite: true,
                sampleCount: 24_000,
                sampleRate: 24_000,
                commandBufferFailureCount: 0,
                rowCapSegments: 0
            )
        )
        #expect(
            !TuringQwenOptimizationBenchmarkRunner.automatedQualityPassed(
                samplesAreFinite: true,
                sampleCount: 24_000,
                sampleRate: 24_000,
                commandBufferFailureCount: 0,
                rowCapSegments: 1
            )
        )
    }

    @Test
    func pcmDigestMismatchIsAnAcceptanceRegressionAndCompletionReason() {
        let regressions = TuringQwenOptimizationBenchmarkRunner
            .acceptanceRegressions(
                caseID: "short-01",
                baselineStatus: .passed,
                currentStatus: .passed,
                baselineQualityPassed: true,
                currentQualityPassed: true,
                baselineAudioDigest: "aaaa",
                currentAudioDigest: "bbbb"
            )
        let comparison = TuringQwenBenchmarkComparison(
            status: "compared",
            baselineLabel: .measured("before"),
            metrics: [],
            matchingCaseCount: .measured(1),
            exactAudioDigestMatchCount: .measured(0),
            qualityRegressions: regressions
        )
        let reasons = TuringQwenOptimizationBenchmarkRunner
            .comparisonFailureReasons(comparison)

        #expect(regressions.count == 1)
        #expect(regressions[0].contains("PCM digest changed"))
        #expect(reasons.count == 1)
        #expect(reasons[0].contains(regressions[0]))
    }

    @Test
    func priorPassToCurrentNonPassIsAnAcceptanceRegression() {
        let regressions = TuringQwenOptimizationBenchmarkRunner
            .acceptanceRegressions(
                caseID: "medium-01",
                baselineStatus: .passed,
                currentStatus: .skipped,
                baselineQualityPassed: true,
                currentQualityPassed: false,
                baselineAudioDigest: "aaaa",
                currentAudioDigest: nil
            )

        #expect(regressions.count == 1)
        #expect(regressions[0].contains("passed the baseline run"))
        #expect(regressions[0].contains("skipped"))
    }

    @Test
    func compatibleComparisonRequiresTenPercentAggregateWarmThroughputGain() {
        let belowThreshold = benchmarkComparisonFixture(
            beforeThroughput: 1.0,
            afterThroughput: 1.099
        )
        let belowReasons = TuringQwenOptimizationBenchmarkRunner
            .comparisonAcceptanceFailureReasons(belowThreshold)
        #expect(belowReasons.count == 1)
        #expect(belowReasons[0].contains("aggregate warm-throughput"))
        #expect(belowReasons[0].contains("required >=10.000%"))

        let atThreshold = benchmarkComparisonFixture(
            beforeThroughput: 1.0,
            afterThroughput: 1.1
        )
        #expect(
            TuringQwenOptimizationBenchmarkRunner
                .comparisonAcceptanceFailureReasons(atThreshold).isEmpty
        )
    }

    @Test
    func compatibleComparisonRequiresExactPCMForEveryCase() {
        let comparison = benchmarkComparisonFixture(
            beforeThroughput: 1.0,
            afterThroughput: 1.2,
            matchingCaseCount: 2,
            exactDigestCount: 1
        )
        let reasons = TuringQwenOptimizationBenchmarkRunner
            .comparisonAcceptanceFailureReasons(comparison)

        #expect(reasons.count == 1)
        #expect(reasons[0].contains("PCM acceptance failed"))
        #expect(reasons[0].contains("1 of 2"))
    }

    @Test
    func baselineCompatibilityLocksModelHardwareBuildConfigurationAndCasePayload() {
        let baseline = benchmarkReportFixture()
        let identical = benchmarkReportFixture()
        let identicalFailures = TuringQwenOptimizationBenchmarkRunner
            .baselineCompatibilityFailures(
                baseline: baseline,
                currentModel: identical.model,
                currentDevice: identical.device,
                currentBuild: identical.build,
                currentConfiguration: identical.configuration,
                currentResults: identical.results
            )
        #expect(identicalFailures.isEmpty)

        let changed = benchmarkReportFixture(
            modelID: "different-model",
            hostName: "different-device",
            buildConfiguration: "debug",
            warmupText: "different warmup",
            caseText: "different case payload"
        )
        let failures = TuringQwenOptimizationBenchmarkRunner
            .baselineCompatibilityFailures(
                baseline: baseline,
                currentModel: changed.model,
                currentDevice: changed.device,
                currentBuild: changed.build,
                currentConfiguration: changed.configuration,
                currentResults: changed.results
            )

        #expect(failures.contains("model.modelID differs"))
        #expect(failures.contains("build.configuration differs"))
        #expect(failures.contains("configuration.warmupText differs"))
        #expect(failures.contains("case payload differs for short-01"))
    }

    @Test
    func baselineCompatibilityAllowsHostnameAliasOnSameHardware() {
        let baseline = benchmarkReportFixture(hostName: "mac.lan")
        let alias = benchmarkReportFixture(hostName: "richards-macbook-air.local")

        let failures = TuringQwenOptimizationBenchmarkRunner
            .baselineCompatibilityFailures(
                baseline: baseline,
                currentModel: alias.model,
                currentDevice: alias.device,
                currentBuild: alias.build,
                currentConfiguration: alias.configuration,
                currentResults: alias.results
            )

        #expect(failures.isEmpty)
    }
}

private func benchmarkExecutionFixture() -> TuringQwenBenchmarkExecution {
    TuringQwenBenchmarkExecution(
        underrunCount: .notApplicable("fixture has no playback"),
        synchronizationBarrierCount: .unavailable("partial counter"),
        hostReadbackElementCount: .measured(16),
        allocationCount: .unavailable("fixture"),
        laneCount: .measured(1),
        laneIdentity: .measured("fresh-0"),
        streamIdentity: .measured("defaultOnly"),
        commandBuffersSubmitted: .measured(2),
        commandBuffersCompleted: .measured(2),
        commandBufferFailures: .measured(0)
    )
}

private func benchmarkComparisonFixture(
    beforeThroughput: Double,
    afterThroughput: Double,
    matchingCaseCount: Int = 1,
    exactDigestCount: Int = 1
) -> TuringQwenBenchmarkComparison {
    TuringQwenBenchmarkComparison(
        status: "compared",
        baselineLabel: .measured("before"),
        metrics: [
            TuringQwenBenchmarkMetricDelta(
                metric: "audioSecondsPerWallSecond",
                before: .measured(beforeThroughput),
                after: .measured(afterThroughput),
                delta: .measured(afterThroughput - beforeThroughput),
                deltaPercent: .measured(
                    ((afterThroughput - beforeThroughput) / beforeThroughput) * 100
                )
            )
        ],
        matchingCaseCount: .measured(matchingCaseCount),
        exactAudioDigestMatchCount: .measured(exactDigestCount),
        qualityRegressions: []
    )
}

private func benchmarkReportFixture(
    modelID: String = "qwen-model",
    hostName: String = "test-device",
    buildConfiguration: String = "release",
    warmupText: String = TuringQwenOptimizationBenchmarkRunner.warmupText,
    caseText: String = "locked case"
) -> TuringQwenOptimizationBenchmarkReport {
    let input = TuringQwenBenchmarkInput(
        id: "short-01",
        tier: .short,
        text: caseText,
        textDigest: TuringQwenBenchmarkDigest.string(caseText),
        characterCount: caseText.utf16.count,
        wordCount: caseText.split(whereSeparator: \.isWhitespace).count,
        segments: [caseText]
    )
    let result = TuringQwenBenchmarkResult(
        status: .passed,
        input: input,
        output: TuringQwenBenchmarkOutput(
            generatedRows: .measured(10),
            audioSeconds: .measured(1),
            sampleCount: .measured(24_000),
            sampleRate: .measured(24_000),
            audioDigest: .measured("pcm-digest"),
            reachedEOSSegments: .measured(1),
            rowCapSegments: .measured(0)
        ),
        timing: TuringQwenBenchmarkTiming(
            requestToFirstRowSeconds: .unavailable("lazy graph"),
            requestToFirstPCMSeconds: .measured(0.5),
            requestToScheduledPlaybackSeconds: .notApplicable("fixture"),
            requestToAudibleCallbackSeconds: .notApplicable("fixture"),
            initialPromptSeconds: .measured(0.1),
            talkerSeconds: .unavailable("lazy graph"),
            codePredictorSeconds: .unavailable("lazy graph"),
            tokenMaterializationSeconds: .measured(0.01),
            speechDecoderSeconds: .measured(0.2),
            totalWallSeconds: .measured(1),
            audioSecondsPerWallSecond: .measured(1),
            rowsPerSecond: .measured(10)
        ),
        memory: TuringQwenBenchmarkMemory(
            processFootprintBeforeMB: .measured(100),
            processFootprintAfterMB: .measured(110),
            peakProcessFootprintMB: .measured(115),
            mlxActiveBeforeMB: .measured(80),
            mlxActiveAfterMB: .measured(85),
            peakMLXActiveMB: .measured(90),
            mlxCacheBeforeMB: .measured(5),
            mlxCacheAfterMB: .measured(5),
            peakMLXCacheMB: .measured(6)
        ),
        execution: benchmarkExecutionFixture(),
        quality: TuringQwenBenchmarkQuality(
            passed: true,
            decodedSegmentCount: 1,
            expectedSegmentCount: 1,
            samplesAreFinite: .measured(true),
            nonEmptyAudio: .measured(true),
            peakAbsoluteSample: .measured(0.5),
            rms: .measured(0.1),
            perceptualAssessment: .unavailable("fixture")
        ),
        thermal: TuringQwenBenchmarkThermal(
            stateBefore: .measured("nominal"),
            stateAfter: .measured("nominal")
        ),
        error: nil
    )
    let aggregate = TuringQwenBenchmarkAggregate(
        caseCount: 1,
        passedCaseCount: 1,
        failedCaseCount: 0,
        segmentCount: 1,
        generatedRows: .measured(10),
        audioSeconds: .measured(1),
        totalWallSeconds: .measured(1),
        audioSecondsPerWallSecond: .measured(1),
        rowsPerSecond: .measured(10),
        synchronizationBarrierCount: .unavailable("partial counter"),
        hostReadbackElementCount: .measured(16),
        tokenMaterializationSeconds: .measured(0.01),
        peakProcessFootprintMB: .measured(115),
        peakMLXActiveMB: .measured(90),
        peakMLXCacheMB: .measured(6),
        commandBufferFailures: .measured(0)
    )
    return TuringQwenOptimizationBenchmarkReport(
        schemaVersion: 2,
        generatedAtUTC: "2026-09-05T00:00:00Z",
        label: "fixture",
        model: TuringQwenBenchmarkModelIdentity(
            modelID: modelID,
            modelRoot: "/tmp/model",
            ttsModelType: "base",
            quantizationBits: .measured(4),
            quantizationGroupSize: .measured(64),
            cloneVoiceID: TuringQwenOptimizationBenchmarkRunner.voiceID,
            cloneVariantID: TuringQwenOptimizationBenchmarkRunner.variantID,
            cloneRevision: .measured("clone-v1")
        ),
        device: TuringQwenBenchmarkDeviceIdentity(
            hostName: hostName,
            operatingSystem: "macOS fixture",
            architecture: "arm64",
            physicalMemoryBytes: 16_000_000_000,
            metalDevice: .measured("fixture GPU")
        ),
        build: TuringQwenBenchmarkBuildIdentity(
            configuration: buildConfiguration,
            gitRevision: .measured("abc123", detail: "workingTree=clean"),
            executable: .measured("/tmp/turing-qwen-benchmark"),
            commandBufferProfile: "deviceDefault"
        ),
        configuration: TuringQwenBenchmarkConfiguration(
            suite: .quick,
            corpusDigest: TuringQwenOptimizationBenchmarkCorpus.digest,
            warmupText: warmupText,
            warmupCount: 1,
            language: "english",
            maxNewRowsPerSegment: TuringQwenOptimizationBenchmarkRunner.maxNewRowsPerSegment,
            referenceWindowStrategy: "full",
            samplingPolicy: "greedyTalker+greedyCodePredictor",
            samplingSeed: TuringQwenOptimizationBenchmarkRunner.samplingSeed,
            performanceMode: "performance",
            playbackRate: 0.85,
            playbackRateApplied: false,
            residencyMode: "sharedImmutableFresh2",
            benchmarkLanePolicy: "one fixed Fresh2 lane; serial segments; default stream"
        ),
        warmup: .measured(1),
        results: [result],
        aggregate: aggregate,
        comparison: TuringQwenBenchmarkComparison(
            status: "baselineNotProvided",
            baselineLabel: .unavailable("fixture"),
            metrics: [],
            matchingCaseCount: .unavailable("fixture"),
            exactAudioDigestMatchCount: .unavailable("fixture"),
            qualityRegressions: []
        ),
        completion: TuringQwenBenchmarkCompletion(
            status: .pass,
            reasons: ["fixture"]
        )
    )
}
