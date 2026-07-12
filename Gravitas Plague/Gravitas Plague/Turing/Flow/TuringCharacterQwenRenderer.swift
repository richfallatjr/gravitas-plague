import Foundation
import TuringQwenNative

struct TuringCharacterRenderReport: Sendable, Equatable {
    let expectedSegmentCount: Int
    let successfulSegmentIndices: Set<Int>
    let skippedSegmentReasons: [Int: String]

    var skippedSegmentIndices: Set<Int> {
        Set(skippedSegmentReasons.keys)
    }

    var isCompleteSuccess: Bool {
        successfulSegmentIndices.count == expectedSegmentCount &&
            skippedSegmentReasons.isEmpty
    }
}


protocol TuringCharacterRendering: Sendable {
    func render(
        segments: [TuringSpeechSegment],
        runID: String,
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished:
            @Sendable @escaping (
                Int,
                TuringComputeGapGeneratedAudio
            ) async -> Void,
        onSkipped:
            @Sendable @escaping (
                Int,
                String
            ) async -> Void
    ) async throws -> TuringCharacterRenderReport
}

protocol TuringCharacterRendererMaking: Sendable {
    func make(
        runtime: TuringCharacterRuntimeDefinition
    ) -> any TuringCharacterRendering
}

struct TuringCharacterQwenRendererFactory:
    TuringCharacterRendererMaking,
    Sendable
{
    func make(
        runtime: TuringCharacterRuntimeDefinition
    ) -> any TuringCharacterRendering {
        TuringCharacterQwenRenderer(
            runtime: runtime
        )
    }
}

actor TuringCharacterQwenRenderer: TuringCharacterRendering {
    typealias StartedCallback =
        @Sendable (Int) async -> Void

    typealias FinishedCallback =
        @Sendable (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void

    typealias SkippedCallback =
        @Sendable (
            Int,
            String
        ) async -> Void

    private let runtime: TuringCharacterRuntimeDefinition
    private let resources: TuringBaseCloneRuntimeResources
    private let arbiter: TuringQwenCharacterPoolArbiter

    init(
        runtime: TuringCharacterRuntimeDefinition,
        resources: TuringBaseCloneRuntimeResources =
            TuringBaseCloneRuntimeResources(),
        arbiter: TuringQwenCharacterPoolArbiter = .shared
    ) {
        self.runtime = runtime
        self.resources = resources
        self.arbiter = arbiter
    }

    func render(
        segments: [TuringSpeechSegment],
        runID: String,
        onStarted: @escaping StartedCallback,
        onFinished: @escaping FinishedCallback,
        onSkipped: @escaping SkippedCallback
    ) async throws -> TuringCharacterRenderReport {
        guard segments.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "\(runtime.characterID) Qwen render requires at least one segment."
            )
        }

        let owner = "\(runtime.characterID).\(runID)"
        await arbiter.acquire(owner: owner)

        var pool: TuringQwenNativeFreshInstancePool?
        let state = TuringCharacterRenderState(
            expectedSegmentCount: segments.count
        )

        do {
            try Task.checkCancellation()

            guard let bundleRoot = Bundle.main.resourceURL else {
                throw TuringRuntimeError.invalidConfig(
                    "Missing app resource root for \(runtime.characterID) clone."
                )
            }

            let profile = try TuringQwenNativeCloneProfileLoader()
                .loadBaseCloneProfile(
                    from: bundleRoot,
                    profileResourcePath:
                        runtime.cloneProfileResourcePath,
                    expectedVoiceID: runtime.voiceID,
                    expectedCharacterID: runtime.characterID,
                    logPrefix: runtime.displayName
                )

            let bundledModel = try resources.locateBundledModel()
            let stagedModel = try resources.stageWritableModel(
                from: bundledModel
            )

            let freshPool =
                try TuringQwenNativeGenerationSchedulerFactory
                    .makeFresh2Pool()
            pool = freshPool

            try await freshPool.warmLoadExactlyRequestedInstances(
                modelRoot: stagedModel,
                cloneProfile: profile,
                variantID: profile.defaultVariantID,
                performanceMode: .performance
            )

            let scheduler =
                TuringQwenNativeGenerationSchedulerFactory
                    .makeFresh2Scheduler(
                        instancePool: freshPool
                    )

            let selectedVariant = try profile.requireVariant(
                profile.defaultVariantID
            )
            let selectedArtifacts =
                try TuringQwenNativeCloneArtifactsLoader()
                    .load(
                        from: selectedVariant,
                        expectedVoiceID: profile.voiceID
                    )

            let referenceRowLimit: Int? =
                runtime.qwen.useExactReferenceRowCount
                ? selectedArtifacts.referenceRowCount
                : nil

            let windowStrategy:
                TuringQwenNativeReferenceWindowStrategy

            switch runtime.qwen.referenceWindowStrategy {
            case "full":
                windowStrategy = .full
            case "suffix":
                windowStrategy = .suffix
            default:
                throw TuringRuntimeError.invalidConfig(
                    "Unsupported referenceWindowStrategy \(runtime.qwen.referenceWindowStrategy)."
                )
            }

            let requests = segments.enumerated().map {
                index,
                segment in

                print("""
                [TuringFlow] exact Qwen input
                  characterID: \(runtime.characterID)
                  voiceID: \(runtime.voiceID)
                  playbackRunID: \(runID)
                  segmentIndex: \(index)
                  qwenInputTextSHA256: \(TuringFlowHash.sha256(segment.text))
                  textUTF16: \(segment.text.utf16.count)
                  BEGIN_TEXT
                \(segment.text)
                  END_TEXT
                """)

                return TuringQwenNativeBaseCloneSegmentRequest(
                    segmentIndex: index,
                    text: segment.text,
                    language: "english",
                    cloneProfile: profile,
                    maxNewRows: runtime.qwen.maxNewRows,
                    performanceMode: .performance,
                    referenceRowLimit: referenceRowLimit,
                    referenceWindowStrategy: windowStrategy
                )
            }

            print("""
            [TuringFlow] Fresh2 pool ready
              characterID: \(runtime.characterID)
              voiceID: \(runtime.voiceID)
              playbackRunID: \(runID)
              requestedInstanceCount: 2
              actualInstanceCount: 2
              sharedWeights: false
              fallbackUsed: false
              referenceRowLimit: \(referenceRowLimit.map(String.init) ?? "full")
              referenceWindowStrategy: \(windowStrategy.rawValue)
            """)

            let report = try await scheduler.renderSegments(
                requests,
                runID: runID,
                skipSegmentFailures:
                    runtime.qwen.skipSegmentFailures,
                onSegmentStarted: {
                    _,
                    segmentIndex in

                    await onStarted(segmentIndex)
                },
                onSegmentFinished: { result in
                    await state.recordSuccess(
                        result.segmentIndex
                    )
                    await onFinished(
                        result.segmentIndex,
                        TuringComputeGapGeneratedAudio(
                            segmentIndex:
                                result.segmentIndex,
                            samples:
                                result.audio.samples,
                            sampleRate:
                                Double(
                                    result.audio.sampleRate
                                ),
                            channelCount: 1
                        )
                    )
                },
                onSegmentSkipped: { skipped in
                    await state.recordSkipped(
                        skipped.segmentIndex,
                        reason:
                            skipped.errorDescription
                    )
                    await onSkipped(
                        skipped.segmentIndex,
                        skipped.errorDescription
                    )
                }
            )

            report.log()

            await freshPool.unloadAll(
                reason:
                    "turingFlow.\(runtime.characterID).finished.\(runID)"
            )
            pool = nil
            await arbiter.release(owner: owner)

            let result = await state.snapshot()
            print("""
            [TuringFlow] character render finished
              characterID: \(runtime.characterID)
              voiceID: \(runtime.voiceID)
              playbackRunID: \(runID)
              expectedSegmentCount: \(result.expectedSegmentCount)
              successfulSegmentIndices: \(result.successfulSegmentIndices.sorted())
              skippedSegmentIndices: \(result.skippedSegmentIndices.sorted())
            """)
            return result
        } catch {
            await pool?.unloadAll(
                reason:
                    "turingFlow.\(runtime.characterID).failed.\(runID)"
            )
            await arbiter.release(owner: owner)
            throw error
        }
    }
}

private actor TuringCharacterRenderState {
    private let expectedSegmentCount: Int
    private var successful = Set<Int>()
    private var skipped: [Int: String] = [:]

    init(expectedSegmentCount: Int) {
        self.expectedSegmentCount = expectedSegmentCount
    }

    func recordSuccess(_ index: Int) {
        successful.insert(index)
        skipped.removeValue(forKey: index)
    }

    func recordSkipped(
        _ index: Int,
        reason: String
    ) {
        guard successful.contains(index) == false else {
            return
        }
        skipped[index] = reason
    }

    func snapshot() -> TuringCharacterRenderReport {
        TuringCharacterRenderReport(
            expectedSegmentCount: expectedSegmentCount,
            successfulSegmentIndices: successful,
            skippedSegmentReasons: skipped
        )
    }
}
