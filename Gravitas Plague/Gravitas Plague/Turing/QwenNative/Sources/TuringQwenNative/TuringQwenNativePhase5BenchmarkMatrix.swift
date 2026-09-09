import Foundation

public struct TuringQwenNativePhase5BenchmarkMatrixOptions: Sendable {
    public let modelRoot: URL
    public let bundleRoot: URL
    public let suite: TuringQwenBenchmarkSuite
    public let label: String

    public init(
        modelRoot: URL,
        bundleRoot: URL,
        suite: TuringQwenBenchmarkSuite,
        label: String
    ) {
        self.modelRoot = modelRoot
        self.bundleRoot = bundleRoot
        self.suite = suite
        self.label = label
    }
}

public struct TuringQwenNativePhase5ModeConfiguration:
    Sendable
{
    public let mode: TuringQwenNativePhase5QualificationMode
    public let requestedLaneCount: Int
    public let laneStreamMode: TuringQwenNativeLaneStreamMode

    public init(
        mode: TuringQwenNativePhase5QualificationMode
    ) throws {
        guard mode != .microbatch2 else {
            throw TuringQwenNativeError.invalidConfig(
                "microbatch2 has no executable configuration until batched KV-cache and sampling exist."
            )
        }
        self.mode = mode
        self.requestedLaneCount = mode.requestedLaneCount
        switch mode.executionStrategy {
        case .defaultGPUStream:
            self.laneStreamMode = .defaultOnly
        case .perTaskGPUStream:
            self.laneStreamMode = .dedicatedGPU
        case .microbatch:
            throw TuringQwenNativeError.invalidConfig(
                "An unsupported microbatch strategy cannot be configured."
            )
        }
    }
}

public struct TuringQwenNativePhase5ModeObservation:
    Equatable,
    Sendable
{
    public let actualLaneCount: Int
    public let firstPCMSeconds: Double
    public let firstCompletedSegmentSeconds: Double
    public let aggregateGeneratedAudioSeconds: Double
    public let aggregateWallSeconds: Double
    public let expectedSegmentCount: Int
    public let completedSegmentIndices: [Int]
    public let perSegmentPCMDigests: [Int: String]
    public let nonemptyAudioForEveryCompletedSegment: Bool
    public let consistentSampleRate: Int?
    public let currentPhysicalFootprintMB: Double
    public let currentResidentSizeMB: Double
    public let postRunMLXActiveMemoryMB: Double
    public let postRunMLXCacheMemoryMB: Double
    public let mlxCacheLimitMB: Int
    public let memoryGuardDowngraded: Bool
    public let schedulerReportedUnderrunCount: Int

    public init(
        actualLaneCount: Int,
        firstPCMSeconds: Double,
        firstCompletedSegmentSeconds: Double,
        aggregateGeneratedAudioSeconds: Double,
        aggregateWallSeconds: Double,
        expectedSegmentCount: Int,
        completedSegmentIndices: [Int],
        perSegmentPCMDigests: [Int: String],
        nonemptyAudioForEveryCompletedSegment: Bool,
        consistentSampleRate: Int?,
        currentPhysicalFootprintMB: Double = 0,
        currentResidentSizeMB: Double = 0,
        postRunMLXActiveMemoryMB: Double = 0,
        postRunMLXCacheMemoryMB: Double = 0,
        mlxCacheLimitMB: Int = 0,
        memoryGuardDowngraded: Bool = false,
        schedulerReportedUnderrunCount: Int = 0
    ) throws {
        let uniqueCompletedSegmentIndices = Set(completedSegmentIndices)
        guard actualLaneCount > 0,
              firstPCMSeconds.isFinite,
              firstPCMSeconds >= 0,
              firstCompletedSegmentSeconds.isFinite,
              firstCompletedSegmentSeconds >= 0,
              aggregateGeneratedAudioSeconds.isFinite,
              aggregateGeneratedAudioSeconds > 0,
              aggregateWallSeconds.isFinite,
              aggregateWallSeconds > 0,
              expectedSegmentCount > 0,
              !completedSegmentIndices.isEmpty,
              !perSegmentPCMDigests.isEmpty,
              perSegmentPCMDigests.values.allSatisfy({ !$0.isEmpty }),
              Set(perSegmentPCMDigests.keys) ==
                uniqueCompletedSegmentIndices,
              currentPhysicalFootprintMB.isFinite,
              currentPhysicalFootprintMB >= 0,
              currentResidentSizeMB.isFinite,
              currentResidentSizeMB >= 0,
              postRunMLXActiveMemoryMB.isFinite,
              postRunMLXActiveMemoryMB >= 0,
              postRunMLXCacheMemoryMB.isFinite,
              postRunMLXCacheMemoryMB >= 0,
              mlxCacheLimitMB >= 0,
              schedulerReportedUnderrunCount >= 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Phase 5 mode observation is incomplete or invalid."
            )
        }
        self.actualLaneCount = actualLaneCount
        self.firstPCMSeconds = firstPCMSeconds
        self.firstCompletedSegmentSeconds = firstCompletedSegmentSeconds
        self.aggregateGeneratedAudioSeconds = aggregateGeneratedAudioSeconds
        self.aggregateWallSeconds = aggregateWallSeconds
        self.expectedSegmentCount = expectedSegmentCount
        self.completedSegmentIndices = completedSegmentIndices
        self.perSegmentPCMDigests = perSegmentPCMDigests
        self.nonemptyAudioForEveryCompletedSegment =
            nonemptyAudioForEveryCompletedSegment
        self.consistentSampleRate = consistentSampleRate
        self.currentPhysicalFootprintMB = currentPhysicalFootprintMB
        self.currentResidentSizeMB = currentResidentSizeMB
        self.postRunMLXActiveMemoryMB = postRunMLXActiveMemoryMB
        self.postRunMLXCacheMemoryMB = postRunMLXCacheMemoryMB
        self.mlxCacheLimitMB = mlxCacheLimitMB
        self.memoryGuardDowngraded = memoryGuardDowngraded
        self.schedulerReportedUnderrunCount =
            schedulerReportedUnderrunCount
    }

    public var aggregateAudioSecondsPerWallSecond: Double {
        aggregateGeneratedAudioSeconds / aggregateWallSeconds
    }
}

public enum TuringQwenNativePhase5MatrixResultStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case passed
    case failed
    case unsupported
    case notRun
}

public enum TuringQwenNativePhase5PCMObservationKind:
    String,
    Codable,
    Sendable
{
    /// The qualification lane returned a complete decoded segment. This is a
    /// real PCM-availability timestamp but is not a Stage 4 activation claim.
    case completedSegmentReturn
    case unavailable
}

public struct TuringQwenNativePhase5MatrixResult:
    Codable,
    Sendable
{
    public let mode: TuringQwenNativePhase5QualificationMode
    public let capability: TuringQwenNativePhase5ModeCapability
    public let status: TuringQwenNativePhase5MatrixResultStatus
    public let executionHarness: String
    public let isExactShippingTopology: Bool
    public let requestedLaneCount: Int
    public let actualLaneCount: TuringQwenBenchmarkMeasurement<Int>
    public let laneStreamMode: TuringQwenBenchmarkMeasurement<String>
    public let firstPCMObservationKind:
        TuringQwenNativePhase5PCMObservationKind
    public let firstPCMSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let firstCompletedSegmentSeconds:
        TuringQwenBenchmarkMeasurement<Double>
    public let aggregateGeneratedAudioSeconds:
        TuringQwenBenchmarkMeasurement<Double>
    public let aggregateWallSeconds: TuringQwenBenchmarkMeasurement<Double>
    public let aggregateAudioSecondsPerWallSecond:
        TuringQwenBenchmarkMeasurement<Double>
    public let expectedSegmentCount: Int
    /// Completion order is diagnostic scheduling evidence, not playback order.
    public let completedSegmentIndices: [Int]
    public let perSegmentPCMDigests: [String: String]
    public let missingSegmentCount: TuringQwenBenchmarkMeasurement<Int>
    public let duplicateSegmentCount: TuringQwenBenchmarkMeasurement<Int>
    public let nonemptyAudioForEveryCompletedSegment:
        TuringQwenBenchmarkMeasurement<Bool>
    public let consistentSampleRate: TuringQwenBenchmarkMeasurement<Int>
    public let stage4StreamingActive:
        TuringQwenBenchmarkMeasurement<Bool>
    public let playbackUnderrunCount: TuringQwenBenchmarkMeasurement<Int>
    public let orderedPlaybackPassed: TuringQwenBenchmarkMeasurement<Bool>
    public let cloneQualityPassed: TuringQwenBenchmarkMeasurement<Bool>
    public let currentPhysicalFootprintMB:
        TuringQwenBenchmarkMeasurement<Double>
    public let currentResidentSizeMB: TuringQwenBenchmarkMeasurement<Double>
    public let postRunMLXActiveMemoryMB:
        TuringQwenBenchmarkMeasurement<Double>
    public let postRunMLXCacheMemoryMB:
        TuringQwenBenchmarkMeasurement<Double>
    public let peakMLXActiveMemoryMB: TuringQwenBenchmarkMeasurement<Double>
    public let peakMLXCacheMemoryMB: TuringQwenBenchmarkMeasurement<Double>
    public let mlxCacheLimitMB: TuringQwenBenchmarkMeasurement<Int>
    public let memoryGuardDowngraded: TuringQwenBenchmarkMeasurement<Bool>
    public let schedulerReportedUnderrunCount:
        TuringQwenBenchmarkMeasurement<Int>
    public let commandBufferFailures: TuringQwenBenchmarkMeasurement<Int>
    public let thermalState: TuringQwenBenchmarkMeasurement<String>
    public let error: String?
}

public enum TuringQwenNativePhase5MatrixPromotionStatus:
    String,
    Codable,
    Sendable
{
    case notEvaluated
}

public struct TuringQwenNativePhase5ShippingTopologyReference:
    Codable,
    Equatable,
    Sendable
{
    public let residencyMode: String
    public let laneCount: Int
    public let laneStreamMode: String
    public let gpuAdmissionMode: String

    public static let current = Self(
        residencyMode: TuringQwenNativeResidencyMode.independentFresh2.rawValue,
        laneCount: 2,
        laneStreamMode: TuringQwenNativeLaneStreamMode.defaultOnly.rawValue,
        gpuAdmissionMode:
            TuringQwenNativeGPUAdmissionMode.currentOverlap.rawValue
    )
}

public struct TuringQwenNativePhase5PCMDigestComparison:
    Codable,
    Sendable
{
    public let candidateMode: TuringQwenNativePhase5QualificationMode
    public let exactMatchToApproximateControl:
        TuringQwenBenchmarkMeasurement<Bool>
    public let matchingSegmentCount: TuringQwenBenchmarkMeasurement<Int>
    public let mismatchedSegmentIndices: [Int]
}

public struct TuringQwenNativePhase5MetricComparison:
    Codable,
    Sendable
{
    public let candidateMode: TuringQwenNativePhase5QualificationMode
    /// Candidate minus approximate-control for the segment needed first by
    /// ordered playback; zero or negative is better.
    public let nextRequiredPCMDeltaSeconds:
        TuringQwenBenchmarkMeasurement<Double>
    public let nextRequiredPCMIsNeutralOrBetter:
        TuringQwenBenchmarkMeasurement<Bool>
    /// Candidate minus approximate-control; zero or positive is better.
    public let aggregateAudioSecondsPerWallSecondDelta:
        TuringQwenBenchmarkMeasurement<Double>
    public let aggregateThroughputIsNeutralOrBetter:
        TuringQwenBenchmarkMeasurement<Bool>
}

public struct TuringQwenNativePhase5BenchmarkMatrixReport:
    Codable,
    Sendable
{
    public let schemaVersion: Int
    public let generatedAtUTC: String
    public let label: String
    public let suite: TuringQwenBenchmarkSuite
    public let corpusDigest: String
    public let controlMode: TuringQwenNativePhase5QualificationMode
    public let matrixScope: String
    public let exactShippingTopologyReference:
        TuringQwenNativePhase5ShippingTopologyReference
    public let exactShippingControlExecuted: Bool
    public let deterministicModeOrder:
        [TuringQwenNativePhase5QualificationMode]
    public let results: [TuringQwenNativePhase5MatrixResult]
    public let pcmComparisonsToApproximateControl:
        [TuringQwenNativePhase5PCMDigestComparison]
    public let metricComparisonsToApproximateControl:
        [TuringQwenNativePhase5MetricComparison]
    public let promotionStatus: TuringQwenNativePhase5MatrixPromotionStatus
    public let promotionReasons: [String]
    public let automaticPromotionPerformed: Bool
    public let shippingTopologyChanged: Bool

    public var supportedModeFailureCount: Int {
        results.filter { result in
            result.capability.isSupported && result.status != .passed
        }.count
    }
}

public enum TuringQwenNativePhase5BenchmarkMatrixRunner {
    public static let deterministicModeOrder:
        [TuringQwenNativePhase5QualificationMode] = [
            .currentTwoLaneDefaultStreamControl,
            .singleLane,
            .threeLaneDefaultStream,
            .twoLanePerStream,
            .threeLanePerStream,
            .microbatch2
        ]

    public typealias ModeExecutor = @Sendable (
        TuringQwenNativePhase5ModeConfiguration
    ) async throws -> TuringQwenNativePhase5ModeObservation

    /// Executes the matrix serially in a fixed order. Unsupported modes are
    /// reported and never passed to the executor. The first supported-mode
    /// failure fail-stops execution because an MLX/Metal failure can poison the
    /// process; later supported modes are recorded as not run.
    public static func runMatrix(
        label: String,
        suite: TuringQwenBenchmarkSuite,
        corpusDigest: String,
        capabilities: TuringQwenNativePhase5CapabilitySet =
            .installedMLXSwift,
        generatedAtUTC: String = ISO8601DateFormatter().string(from: Date()),
        execute: @escaping ModeExecutor
    ) async -> TuringQwenNativePhase5BenchmarkMatrixReport {
        var results: [TuringQwenNativePhase5MatrixResult] = []
        var cascadeBlockReason: String?
        for mode in deterministicModeOrder {
            let capability = capabilities.classify(mode)
            guard capability.isSupported else {
                results.append(unsupportedResult(capability: capability))
                continue
            }
            if let cascadeBlockReason {
                results.append(
                    notRunResult(
                        mode: mode,
                        capability: capability,
                        reason: cascadeBlockReason
                    )
                )
                continue
            }

            do {
                let configuration = try TuringQwenNativePhase5ModeConfiguration(
                    mode: mode
                )
                let observation = try await execute(configuration)
                let result = measuredResult(
                    configuration: configuration,
                    capability: capability,
                    observation: observation
                )
                results.append(result)
                if result.status != .passed {
                    cascadeBlockReason =
                        "A prior supported Phase 5 mode failed its result gates; later MLX modes were not run in the same process."
                }
            } catch {
                results.append(
                    failedResult(
                        mode: mode,
                        capability: capability,
                        error: error
                    )
                )
                cascadeBlockReason =
                    "A prior supported Phase 5 mode failed with \(error.localizedDescription); later MLX modes were not run in the same process."
            }
        }

        let digestComparisons = makeDigestComparisons(results: results)
        let metricComparisons = makeMetricComparisons(results: results)

        return .init(
            schemaVersion: 1,
            generatedAtUTC: generatedAtUTC,
            label: label,
            suite: suite,
            corpusDigest: corpusDigest,
            controlMode: .currentTwoLaneDefaultStreamControl,
            matrixScope: "isolatedRawLaneTopologyApproximation",
            exactShippingTopologyReference: .current,
            exactShippingControlExecuted: false,
            deterministicModeOrder: deterministicModeOrder,
            results: results,
            pcmComparisonsToApproximateControl: digestComparisons,
            metricComparisonsToApproximateControl: metricComparisons,
            promotionStatus: .notEvaluated,
            promotionReasons: [
                "The matrix uses the isolated shared-weight ParallelLanePool to compare raw lane and stream scheduling. Its two-lane/default-stream row is an approximation, not the exact independentFresh2 shipping control.",
                "This matrix does not exercise the production Stage 4 PCM path and therefore does not claim Stage 4 is active.",
                "Actual playback underruns, ordered delivery, Stage 4 overhead, and listening clone quality are unavailable in this CLI harness.",
                "Phase 5 promotion requires separate measured evidence through TuringQwenNativePhase5PromotionPolicy."
            ],
            automaticPromotionPerformed: false,
            shippingTopologyChanged: false
        )
    }

    /// One-invocation, real-model entry point used by the benchmark CLI.
    public static func run(
        options: TuringQwenNativePhase5BenchmarkMatrixOptions
    ) async -> TuringQwenNativePhase5BenchmarkMatrixReport {
        let cases = TuringQwenOptimizationBenchmarkCorpus.cases(
            for: options.suite
        )
        let capabilities = TuringQwenNativePhase5CapabilitySet.installedMLXSwift

        do {
            let loadedProfile = try TuringQwenNativeCloneProfileLoader()
                .loadBigMikeBaseCloneProfile(
                    from: options.bundleRoot,
                    voiceID: TuringQwenOptimizationBenchmarkRunner.voiceID
                )
            _ = try loadedProfile.requireVariant(
                TuringQwenOptimizationBenchmarkRunner.variantID
            )
            let profile = lockedProfile(from: loadedProfile)
            let config = try TuringQwenNativeConfig.load(from: options.modelRoot)
            try config.validateBaseCloneRuntime()

            return await runMatrix(
                label: options.label,
                suite: options.suite,
                corpusDigest: TuringQwenOptimizationBenchmarkCorpus.digest,
                capabilities: capabilities
            ) { modeConfiguration in
                try await executeRealModelMode(
                    modeConfiguration,
                    modelRoot: options.modelRoot,
                    profile: profile,
                    cases: cases
                )
            }
        } catch {
            let setupFailure = error.localizedDescription
            return await runMatrix(
                label: options.label,
                suite: options.suite,
                corpusDigest: TuringQwenOptimizationBenchmarkCorpus.digest,
                capabilities: capabilities
            ) { _ in
                throw TuringQwenNativeError.invalidConfig(
                    "Phase 5 matrix setup failed: \(setupFailure)"
                )
            }
        }
    }

    private static func executeRealModelMode(
        _ configuration: TuringQwenNativePhase5ModeConfiguration,
        modelRoot: URL,
        profile: TuringQwenNativeCloneProfile,
        cases: [TuringQwenBenchmarkCase]
    ) async throws -> TuringQwenNativePhase5ModeObservation {
        let pool = try TuringQwenNativeParallelLanePool(
            modelRoot: modelRoot,
            laneCountRequested: configuration.requestedLaneCount,
            streamMode: configuration.laneStreamMode
        )
        let actualLaneCount = await pool.laneCountActive

        do {
            guard actualLaneCount == configuration.requestedLaneCount else {
                throw TuringQwenNativeError.invalidConfig(
                    "Phase 5 mode \(configuration.mode.rawValue) requested \(configuration.requestedLaneCount) lanes but the memory guard admitted \(actualLaneCount); the topology is not comparable."
                )
            }

            // Warm every admitted engine/stream before starting the measured
            // clock. Warming only lane zero would make secondary lanes pay
            // first-use compilation and static-context costs during the run.
            for laneID in 0..<actualLaneCount {
                let warmup = makeRequest(
                    segmentIndex: 10_000 + laneID,
                    text: TuringQwenOptimizationBenchmarkRunner.warmupText,
                    profile: profile
                )
                _ = try await pool.render(request: warmup, laneID: laneID)
            }

            let requests = cases.flatMap(\.segments).enumerated().map {
                offset,
                text in
                makeRequest(
                    segmentIndex: offset + 1,
                    text: text,
                    profile: profile
                )
            }
            guard let firstRequest = requests.first else {
                throw TuringQwenNativeError.invalidConfig(
                    "Phase 5 matrix corpus contains no segments."
                )
            }
            let collector = Phase5ModeObservationCollector(
                expectedSegmentCount: requests.count,
                nextRequiredSegmentIndex: firstRequest.segmentIndex
            )
            let scheduler = TuringQwenNativeParallelScheduler(lanePool: pool)
            let runID = "phase5-\(configuration.mode.rawValue)"
            let report = try await scheduler.renderSegments(
                requests,
                runID: runID,
                skipSegmentFailures: false,
                onSegmentStarted: { _, _ in },
                onSegmentFinished: { generated in
                    let completedAt = Date()
                    let digest = PCMHash.digest(generated.audio.samples)
                    await collector.record(
                        generated,
                        pcmHash: digest,
                        completedAt: completedAt
                    )
                }
            )
            let observation = try await collector.makeObservation(
                actualLaneCount: report.laneCountActive,
                aggregateGeneratedAudioSeconds:
                    report.totalGeneratedAudioSeconds,
                aggregateWallSeconds: report.wallClockRenderSeconds,
                currentPhysicalFootprintMB: report.currentPhysFootprintMB,
                currentResidentSizeMB: report.currentResidentSizeMB,
                postRunMLXActiveMemoryMB: report.peakMLXActiveMemoryMB,
                postRunMLXCacheMemoryMB: report.peakMLXCacheMemoryMB,
                mlxCacheLimitMB: report.cacheLimitMB,
                memoryGuardDowngraded: report.memoryGuardDowngraded,
                schedulerReportedUnderrunCount:
                    report.orderedPlaybackUnderrunCount
            )
            await pool.releaseResidentResources(
                reason: "phase5MatrixModeFinished"
            )
            return observation
        } catch {
            await pool.releaseResidentResources(
                reason: "phase5MatrixModeFailed"
            )
            throw error
        }
    }

    private static func makeRequest(
        segmentIndex: Int,
        text: String,
        profile: TuringQwenNativeCloneProfile
    ) -> TuringQwenNativeBaseCloneSegmentRequest {
        TuringQwenNativeBaseCloneSegmentRequest(
            segmentIndex: segmentIndex,
            text: text,
            language: "english",
            cloneProfile: profile,
            maxNewRows:
                TuringQwenOptimizationBenchmarkRunner.maxNewRowsPerSegment,
            performanceMode: .performance,
            referenceRowLimit: nil,
            referenceWindowStrategy: .full,
            samplingPolicy: .greedy,
            samplingSeed:
                TuringQwenOptimizationBenchmarkRunner.samplingSeed &+
                UInt64(segmentIndex),
            generationQualityPolicy: .permissive
        )
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
            defaultVariantID: TuringQwenOptimizationBenchmarkRunner.variantID,
            allowFallback: false,
            variants: profile.variants
        )
    }

    private static func measuredResult(
        configuration: TuringQwenNativePhase5ModeConfiguration,
        capability: TuringQwenNativePhase5ModeCapability,
        observation: TuringQwenNativePhase5ModeObservation
    ) -> TuringQwenNativePhase5MatrixResult {
        let uniqueCompleted = Set(observation.completedSegmentIndices)
        let duplicateCount = observation.completedSegmentIndices.count -
            uniqueCompleted.count
        let missingCount = max(
            0,
            observation.expectedSegmentCount - uniqueCompleted.count
        )
        let passed = observation.actualLaneCount ==
            configuration.requestedLaneCount &&
            missingCount == 0 &&
            duplicateCount == 0 &&
            observation.nonemptyAudioForEveryCompletedSegment &&
            observation.consistentSampleRate == 24_000

        return .init(
            mode: configuration.mode,
            capability: capability,
            status: passed ? .passed : .failed,
            executionHarness: "isolatedSharedWeightParallelLanePool",
            isExactShippingTopology: false,
            requestedLaneCount: configuration.requestedLaneCount,
            actualLaneCount: .measured(observation.actualLaneCount),
            laneStreamMode: .measured(configuration.laneStreamMode.rawValue),
            firstPCMObservationKind: .completedSegmentReturn,
            firstPCMSeconds: .measured(
                observation.firstPCMSeconds,
                detail: "Decoded PCM for the segment required first by ordered playback; this is not an incremental Stage 4 callback."
            ),
            firstCompletedSegmentSeconds: .measured(
                observation.firstCompletedSegmentSeconds,
                detail: "First completion from any qualification lane; it may belong to a later segment and is not the ordered-playback latency."
            ),
            aggregateGeneratedAudioSeconds: .measured(
                observation.aggregateGeneratedAudioSeconds
            ),
            aggregateWallSeconds: .measured(observation.aggregateWallSeconds),
            aggregateAudioSecondsPerWallSecond: .measured(
                observation.aggregateAudioSecondsPerWallSecond
            ),
            expectedSegmentCount: observation.expectedSegmentCount,
            completedSegmentIndices: observation.completedSegmentIndices,
            perSegmentPCMDigests: Dictionary(
                uniqueKeysWithValues: observation.perSegmentPCMDigests.map {
                    (String($0.key), $0.value)
                }
            ),
            missingSegmentCount: .measured(missingCount),
            duplicateSegmentCount: .measured(duplicateCount),
            nonemptyAudioForEveryCompletedSegment: .measured(
                observation.nonemptyAudioForEveryCompletedSegment
            ),
            consistentSampleRate: observation.consistentSampleRate.map {
                .measured($0)
            } ?? .unavailable("Completed segments did not share one sample rate."),
            stage4StreamingActive: .unavailable(
                "The Phase 5 topology matrix does not exercise or claim production Stage 4 streaming."
            ),
            playbackUnderrunCount: .unavailable(
                "The native package matrix does not schedule device playback."
            ),
            orderedPlaybackPassed: .unavailable(
                "Completion order is recorded, but the package matrix does not exercise the production ordered-playback owner."
            ),
            cloneQualityPassed: .unavailable(
                "Automated nonempty/sample-rate checks are not a listening clone-quality decision."
            ),
            currentPhysicalFootprintMB: .measured(
                observation.currentPhysicalFootprintMB
            ),
            currentResidentSizeMB: .measured(
                observation.currentResidentSizeMB
            ),
            postRunMLXActiveMemoryMB: .measured(
                observation.postRunMLXActiveMemoryMB,
                detail: "This is the legacy report's end-of-run MLX active-memory snapshot, not a sampled peak."
            ),
            postRunMLXCacheMemoryMB: .measured(
                observation.postRunMLXCacheMemoryMB,
                detail: "This is the legacy report's end-of-run MLX cache-memory snapshot, not a sampled peak."
            ),
            peakMLXActiveMemoryMB: .unavailable(
                "The isolated legacy lane harness does not sample MLX active-memory peaks."
            ),
            peakMLXCacheMemoryMB: .unavailable(
                "The isolated legacy lane harness does not sample MLX cache-memory peaks."
            ),
            mlxCacheLimitMB: .measured(observation.mlxCacheLimitMB),
            memoryGuardDowngraded: .measured(
                observation.memoryGuardDowngraded
            ),
            schedulerReportedUnderrunCount: .measured(
                observation.schedulerReportedUnderrunCount,
                detail: "The isolated scheduler exposes this counter, but no audio-device playback occurs in the matrix."
            ),
            commandBufferFailures: .unavailable(
                "The legacy raw-lane report does not expose command-buffer totals."
            ),
            thermalState: .unavailable(
                "The legacy raw-lane report does not sample thermal state."
            ),
            error: passed ? nil :
                "The mode did not preserve requested lanes, complete each segment exactly once, or return nonempty 24 kHz audio."
        )
    }

    private static func unsupportedResult(
        capability: TuringQwenNativePhase5ModeCapability
    ) -> TuringQwenNativePhase5MatrixResult {
        let missing = capability.missingCapabilities.map(\.rawValue)
            .joined(separator: ",")
        let reason = "Unsupported by installed engine capabilities: \(missing)."
        return unavailableResult(
            mode: capability.mode,
            capability: capability,
            status: .unsupported,
            reason: reason
        )
    }

    private static func failedResult(
        mode: TuringQwenNativePhase5QualificationMode,
        capability: TuringQwenNativePhase5ModeCapability,
        error: Error
    ) -> TuringQwenNativePhase5MatrixResult {
        unavailableResult(
            mode: mode,
            capability: capability,
            status: .failed,
            reason: error.localizedDescription
        )
    }

    private static func notRunResult(
        mode: TuringQwenNativePhase5QualificationMode,
        capability: TuringQwenNativePhase5ModeCapability,
        reason: String
    ) -> TuringQwenNativePhase5MatrixResult {
        unavailableResult(
            mode: mode,
            capability: capability,
            status: .notRun,
            reason: reason
        )
    }

    private static func makeDigestComparisons(
        results: [TuringQwenNativePhase5MatrixResult]
    ) -> [TuringQwenNativePhase5PCMDigestComparison] {
        guard let control = results.first(where: {
            $0.mode == .currentTwoLaneDefaultStreamControl
        }), control.status == .passed else {
            let reason =
                "The isolated two-lane/default-stream approximation did not complete, so no PCM digest comparison is possible."
            return deterministicModeOrder.dropFirst().map { mode in
                .init(
                    candidateMode: mode,
                    exactMatchToApproximateControl: .unavailable(reason),
                    matchingSegmentCount: .unavailable(reason),
                    mismatchedSegmentIndices: []
                )
            }
        }

        return deterministicModeOrder.dropFirst().map { mode in
            guard let candidate = results.first(where: { $0.mode == mode }),
                  candidate.status == .passed else {
                let reason =
                    "Candidate mode did not complete successfully; exact PCM digest parity was not measured."
                return .init(
                    candidateMode: mode,
                    exactMatchToApproximateControl: .unavailable(reason),
                    matchingSegmentCount: .unavailable(reason),
                    mismatchedSegmentIndices: []
                )
            }

            let segmentIndices = Set(
                control.perSegmentPCMDigests.keys.compactMap(Int.init)
            ).union(
                candidate.perSegmentPCMDigests.keys.compactMap(Int.init)
            ).sorted()
            let mismatched = segmentIndices.filter { segmentIndex in
                control.perSegmentPCMDigests[String(segmentIndex)] !=
                    candidate.perSegmentPCMDigests[String(segmentIndex)]
            }
            return .init(
                candidateMode: mode,
                exactMatchToApproximateControl: .measured(
                    mismatched.isEmpty,
                    detail: mismatched.isEmpty
                        ? "Every completed segment's Float32 PCM digest matches the isolated two-lane/default-stream approximation."
                        : "Digest differences are reported as evidence; they do not imply automatic rejection or promotion and still require listening review."
                ),
                matchingSegmentCount: .measured(
                    segmentIndices.count - mismatched.count
                ),
                mismatchedSegmentIndices: mismatched
            )
        }
    }

    private static func makeMetricComparisons(
        results: [TuringQwenNativePhase5MatrixResult]
    ) -> [TuringQwenNativePhase5MetricComparison] {
        guard let control = results.first(where: {
            $0.mode == .currentTwoLaneDefaultStreamControl
        }), control.status == .passed,
        let controlNextRequiredPCM = control.firstPCMSeconds.value,
        let controlThroughput =
            control.aggregateAudioSecondsPerWallSecond.value else {
            return deterministicModeOrder.dropFirst().map { mode in
                unavailableMetricComparison(
                    mode: mode,
                    reason: "The isolated two-lane/default-stream approximation has no complete timing baseline."
                )
            }
        }

        return deterministicModeOrder.dropFirst().map { mode in
            guard let candidate = results.first(where: { $0.mode == mode }),
                  candidate.status == .passed,
                  let candidateNextRequiredPCM =
                    candidate.firstPCMSeconds.value,
                  let candidateThroughput =
                    candidate.aggregateAudioSecondsPerWallSecond.value else {
                return unavailableMetricComparison(
                    mode: mode,
                    reason: "Candidate mode did not produce complete comparable timing evidence."
                )
            }
            let nextRequiredPCMDelta = candidateNextRequiredPCM -
                controlNextRequiredPCM
            let throughputDelta = candidateThroughput - controlThroughput
            return .init(
                candidateMode: mode,
                nextRequiredPCMDeltaSeconds: .measured(
                    nextRequiredPCMDelta
                ),
                nextRequiredPCMIsNeutralOrBetter: .measured(
                    nextRequiredPCMDelta <= 0
                ),
                aggregateAudioSecondsPerWallSecondDelta: .measured(
                    throughputDelta
                ),
                aggregateThroughputIsNeutralOrBetter: .measured(
                    throughputDelta >= 0
                )
            )
        }
    }

    private static func unavailableMetricComparison(
        mode: TuringQwenNativePhase5QualificationMode,
        reason: String
    ) -> TuringQwenNativePhase5MetricComparison {
        .init(
            candidateMode: mode,
            nextRequiredPCMDeltaSeconds: .unavailable(reason),
            nextRequiredPCMIsNeutralOrBetter: .unavailable(reason),
            aggregateAudioSecondsPerWallSecondDelta: .unavailable(reason),
            aggregateThroughputIsNeutralOrBetter: .unavailable(reason)
        )
    }

    private static func unavailableResult(
        mode: TuringQwenNativePhase5QualificationMode,
        capability: TuringQwenNativePhase5ModeCapability,
        status: TuringQwenNativePhase5MatrixResultStatus,
        reason: String
    ) -> TuringQwenNativePhase5MatrixResult {
        .init(
            mode: mode,
            capability: capability,
            status: status,
            executionHarness: "isolatedSharedWeightParallelLanePool",
            isExactShippingTopology: false,
            requestedLaneCount: mode.requestedLaneCount,
            actualLaneCount: .unavailable(reason),
            laneStreamMode: .unavailable(reason),
            firstPCMObservationKind: .unavailable,
            firstPCMSeconds: .unavailable(reason),
            firstCompletedSegmentSeconds: .unavailable(reason),
            aggregateGeneratedAudioSeconds: .unavailable(reason),
            aggregateWallSeconds: .unavailable(reason),
            aggregateAudioSecondsPerWallSecond: .unavailable(reason),
            expectedSegmentCount: 0,
            completedSegmentIndices: [],
            perSegmentPCMDigests: [:],
            missingSegmentCount: .unavailable(reason),
            duplicateSegmentCount: .unavailable(reason),
            nonemptyAudioForEveryCompletedSegment: .unavailable(reason),
            consistentSampleRate: .unavailable(reason),
            stage4StreamingActive: .unavailable(
                "The Phase 5 topology matrix does not exercise or claim production Stage 4 streaming."
            ),
            playbackUnderrunCount: .unavailable(reason),
            orderedPlaybackPassed: .unavailable(reason),
            cloneQualityPassed: .unavailable(reason),
            currentPhysicalFootprintMB: .unavailable(reason),
            currentResidentSizeMB: .unavailable(reason),
            postRunMLXActiveMemoryMB: .unavailable(reason),
            postRunMLXCacheMemoryMB: .unavailable(reason),
            peakMLXActiveMemoryMB: .unavailable(reason),
            peakMLXCacheMemoryMB: .unavailable(reason),
            mlxCacheLimitMB: .unavailable(reason),
            memoryGuardDowngraded: .unavailable(reason),
            schedulerReportedUnderrunCount: .unavailable(reason),
            commandBufferFailures: .unavailable(reason),
            thermalState: .unavailable(reason),
            error: reason
        )
    }
}

private actor Phase5ModeObservationCollector {
    private let expectedSegmentCount: Int
    private let nextRequiredSegmentIndex: Int
    private let startedAt = Date()
    private var firstAnyCompletedAt: Date?
    private var nextRequiredCompletedAt: Date?
    private var completedSegmentIndices: [Int] = []
    private var perSegmentPCMDigests: [Int: String] = [:]
    private var allAudioNonempty = true
    private var sampleRate: Int?
    private var hasInconsistentSampleRate = false

    init(
        expectedSegmentCount: Int,
        nextRequiredSegmentIndex: Int
    ) {
        self.expectedSegmentCount = expectedSegmentCount
        self.nextRequiredSegmentIndex = nextRequiredSegmentIndex
    }

    func record(
        _ generated: TuringQwenNativeGeneratedAudio,
        pcmHash: String,
        completedAt: Date
    ) {
        if firstAnyCompletedAt == nil {
            firstAnyCompletedAt = completedAt
        }
        if generated.segmentIndex == nextRequiredSegmentIndex,
           nextRequiredCompletedAt == nil {
            nextRequiredCompletedAt = completedAt
        }
        completedSegmentIndices.append(generated.segmentIndex)
        perSegmentPCMDigests[generated.segmentIndex] = pcmHash
        allAudioNonempty = allAudioNonempty &&
            !generated.audio.samples.isEmpty
        if let sampleRate,
           sampleRate != generated.audio.sampleRate {
            hasInconsistentSampleRate = true
        } else if sampleRate == nil {
            sampleRate = generated.audio.sampleRate
        }
    }

    func makeObservation(
        actualLaneCount: Int,
        aggregateGeneratedAudioSeconds: Double,
        aggregateWallSeconds: Double,
        currentPhysicalFootprintMB: Double,
        currentResidentSizeMB: Double,
        postRunMLXActiveMemoryMB: Double,
        postRunMLXCacheMemoryMB: Double,
        mlxCacheLimitMB: Int,
        memoryGuardDowngraded: Bool,
        schedulerReportedUnderrunCount: Int
    ) throws -> TuringQwenNativePhase5ModeObservation {
        guard let firstAnyCompletedAt,
              let nextRequiredCompletedAt else {
            throw TuringQwenNativeError.emptyAudio
        }
        let firstAnyCompletedSeconds = firstAnyCompletedAt
            .timeIntervalSince(startedAt)
        let nextRequiredCompletedSeconds = nextRequiredCompletedAt
            .timeIntervalSince(startedAt)
        return try .init(
            actualLaneCount: actualLaneCount,
            firstPCMSeconds: nextRequiredCompletedSeconds,
            firstCompletedSegmentSeconds: firstAnyCompletedSeconds,
            aggregateGeneratedAudioSeconds: aggregateGeneratedAudioSeconds,
            aggregateWallSeconds: aggregateWallSeconds,
            expectedSegmentCount: expectedSegmentCount,
            completedSegmentIndices: completedSegmentIndices,
            perSegmentPCMDigests: perSegmentPCMDigests,
            nonemptyAudioForEveryCompletedSegment: allAudioNonempty,
            consistentSampleRate: hasInconsistentSampleRate ? nil : sampleRate,
            currentPhysicalFootprintMB: currentPhysicalFootprintMB,
            currentResidentSizeMB: currentResidentSizeMB,
            postRunMLXActiveMemoryMB: postRunMLXActiveMemoryMB,
            postRunMLXCacheMemoryMB: postRunMLXCacheMemoryMB,
            mlxCacheLimitMB: mlxCacheLimitMB,
            memoryGuardDowngraded: memoryGuardDowngraded,
            schedulerReportedUnderrunCount:
                schedulerReportedUnderrunCount
        )
    }
}

private enum PCMHash {
    static func digest(_ samples: [Float]) -> String {
        var accumulator = TuringQwenBenchmarkDigest.Accumulator()
        for sample in samples {
            accumulator.update(float: sample)
        }
        return accumulator.string
    }
}
