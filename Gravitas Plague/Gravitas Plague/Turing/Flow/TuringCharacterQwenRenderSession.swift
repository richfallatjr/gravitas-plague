import Foundation
import TuringQwenNative

protocol TuringCharacterRenderSession: Sendable {
    func begin() async throws

    func renderStage(
        _ stage: TuringCommittedSpeechStage,
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished: @Sendable @escaping (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void,
        onSkipped: @Sendable @escaping (Int, String) async -> Void
    ) async throws -> TuringCharacterRenderReport

    func finish(reason: String) async
    func cancel(reason: String) async
}

protocol TuringCharacterRenderSessionMaking: Sendable {
    func make(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterRenderSession
}

struct TuringCharacterQwenRenderSessionFactory:
    TuringCharacterRenderSessionMaking,
    Sendable
{
    func make(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterRenderSession {
        TuringCharacterQwenRenderSession(
            runtime: runtime,
            runID: runID
        )
    }
}

actor TuringCharacterQwenRenderSession: TuringCharacterRenderSession {
    private let runtime: TuringCharacterRuntimeDefinition
    private let runID: String
    private let resources: TuringBaseCloneRuntimeResources
    private let arbiter: TuringQwenCharacterPoolArbiter

    private var pool: TuringQwenNativeFreshInstancePool?
    private var scheduler: TuringQwenNativeFreshInstanceScheduler?
    private var profile: TuringQwenNativeCloneProfile?
    private var stagedModel: URL?
    private var referenceRowLimit: Int?
    private var windowStrategy:
        TuringQwenNativeReferenceWindowStrategy = .full
    private var ownerID: String?
    private var started = false
    private var finished = false

    init(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String,
        resources: TuringBaseCloneRuntimeResources =
            TuringBaseCloneRuntimeResources(),
        arbiter: TuringQwenCharacterPoolArbiter = .shared
    ) {
        self.runtime = runtime
        self.runID = runID
        self.resources = resources
        self.arbiter = arbiter
    }

    func begin() async throws {
        guard started == false else { return }

        let owner = "\(runtime.characterID).\(runID)"
        await arbiter.acquire(owner: owner)
        ownerID = owner

        do {
            guard let bundleRoot = Bundle.main.resourceURL else {
                throw TuringRuntimeError.invalidConfig(
                    "Missing app resource root for \(runtime.characterID) clone."
                )
            }

            let loadedProfile =
                try TuringQwenNativeCloneProfileLoader()
                    .loadBaseCloneProfile(
                        from: bundleRoot,
                        profileResourcePath:
                            runtime.cloneProfileResourcePath,
                        expectedVoiceID: runtime.voiceID,
                        expectedCharacterID: runtime.characterID,
                        logPrefix: runtime.displayName
                    )
            let bundledModel = try resources.locateBundledModel()
            let writableModel = try resources.stageWritableModel(
                from: bundledModel
            )
            let freshPool =
                try TuringQwenNativeGenerationSchedulerFactory
                    .makeFresh2Pool()
            pool = freshPool

            try await freshPool.warmLoadExactlyRequestedInstances(
                modelRoot: writableModel,
                cloneProfile: loadedProfile,
                variantID: loadedProfile.defaultVariantID,
                performanceMode: .performance
            )

            let selectedVariant = try loadedProfile.requireVariant(
                loadedProfile.defaultVariantID
            )
            let selectedArtifacts =
                try TuringQwenNativeCloneArtifactsLoader().load(
                    from: selectedVariant,
                    expectedVoiceID: loadedProfile.voiceID
                )
            referenceRowLimit = runtime.qwen.useExactReferenceRowCount
                ? selectedArtifacts.referenceRowCount
                : nil

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

            scheduler =
                TuringQwenNativeGenerationSchedulerFactory
                    .makeFresh2Scheduler(instancePool: freshPool)
            profile = loadedProfile
            stagedModel = writableModel
            started = true

            print("""
            [TuringStagedSpeech] Fresh2 render session started
              runID: \(runID)
              characterID: \(runtime.characterID)
              voiceID: \(runtime.voiceID)
              requestedInstanceCount: 2
              actualInstanceCount: 2
              sharedWeights: false
              fallbackUsed: false
            """)
        } catch {
            await pool?.unloadAll(
                reason: "turingFlow.\(runtime.characterID).beginFailed.\(runID)"
            )
            pool = nil
            await releaseOwner(reason: "beginFailed")
            throw error
        }
    }

    func renderStage(
        _ stage: TuringCommittedSpeechStage,
        onStarted: @escaping @Sendable (Int) async -> Void,
        onFinished: @escaping @Sendable (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void,
        onSkipped: @escaping @Sendable (Int, String) async -> Void
    ) async throws -> TuringCharacterRenderReport {
        guard started,
              finished == false,
              let scheduler,
              let profile,
              let stagedModel else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 render session is not active."
            )
        }
        guard stage.globalRange.count == stage.segments.count,
              stage.segments.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Committed stage \(stage.stageID) has an invalid segment range."
            )
        }

        let state = TuringCharacterStageRenderState(
            expectedSegmentCount: stage.segments.count
        )
        let requests = zip(stage.globalRange, stage.segments).map {
            globalIndex,
            segment in

            let samplingSeed = TuringQwenNativeSamplingSeed.make(
                voiceID: runtime.voiceID,
                runID: runID,
                segmentIndex: globalIndex
            )
            print("""
            [TuringFlow] exact Qwen input
              characterID: \(runtime.characterID)
              voiceID: \(runtime.voiceID)
              playbackRunID: \(runID)
              stageID: \(stage.stageID)
              segmentIndex: \(globalIndex)
              qwenInputTextSHA256: \(TuringFlowHash.sha256(segment.text))
              textUTF16: \(segment.text.utf16.count)
              samplingSeed: \(samplingSeed)
              BEGIN_TEXT
            \(segment.text)
              END_TEXT
            """)

            return TuringQwenNativeBaseCloneSegmentRequest(
                segmentIndex: globalIndex,
                text: segment.text,
                language: "english",
                cloneProfile: profile,
                maxNewRows: runtime.qwen.maxNewRows,
                performanceMode: .performance,
                referenceRowLimit: referenceRowLimit,
                referenceWindowStrategy: windowStrategy,
                samplingPolicy: runtime.qwen.samplingPolicy,
                samplingSeed: samplingSeed,
                generationQualityPolicy:
                    runtime.qwen.generationQualityPolicy
            )
        }

        print("""
        [TuringStagedSpeech] stage render started
          runID: \(runID)
          stageID: \(stage.stageID)
          globalRange: \(stage.globalRange)
          segmentCount: \(stage.segments.count)
          freshInstanceCount: 2
        """)

        let nativeReport = try await scheduler.runSegments(
            requests,
            runID: "\(runID).\(stage.stageID)",
            modelRoot: stagedModel,
            skipSegmentFailures: runtime.qwen.skipSegmentFailures,
            onSegmentStarted: { _, segmentIndex in
                await onStarted(segmentIndex)
            },
            onSegmentDecoded: { result in
                await state.recordSuccess(result.segmentIndex)
                await onFinished(
                    result.segmentIndex,
                    TuringComputeGapGeneratedAudio(
                        segmentIndex: result.segmentIndex,
                        samples: result.audio.samples,
                        sampleRate: Double(result.audio.sampleRate),
                        channelCount: 1
                    )
                )
            },
            onSegmentSkipped: { skipped in
                await state.recordSkipped(
                    skipped.segmentIndex,
                    reason: skipped.errorDescription
                )
                await onSkipped(
                    skipped.segmentIndex,
                    skipped.errorDescription
                )
            }
        )
        nativeReport.log()

        let result = await state.snapshot()
        print("""
        [TuringStagedSpeech] stage render completed
          runID: \(runID)
          stageID: \(stage.stageID)
          successfulSegmentIndices: \(result.successfulSegmentIndices.sorted())
          skippedSegmentIndices: \(result.skippedSegmentIndices.sorted())
        """)
        return result
    }

    func finish(reason: String) async {
        guard finished == false else { return }
        finished = true
        await pool?.unloadAll(
            reason: "turingFlow.\(runtime.characterID).\(reason).\(runID)"
        )
        pool = nil
        scheduler = nil
        profile = nil
        stagedModel = nil
        await releaseOwner(reason: reason)
    }

    func cancel(reason: String) async {
        await finish(reason: "cancel.\(reason)")
    }

    private func releaseOwner(reason: String) async {
        guard let ownerID else { return }
        self.ownerID = nil
        await arbiter.release(owner: ownerID)
        print("""
        [TuringStagedSpeech] render-session ownership released
          runID: \(runID)
          reason: \(reason)
        """)
    }
}

private actor TuringCharacterStageRenderState {
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

    func recordSkipped(_ index: Int, reason: String) {
        guard successful.contains(index) == false else { return }
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
