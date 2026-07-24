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
    TuringCharacterStreamingRenderSessionMaking,
    Sendable
{
    private let highMemoryPreflight:
        any TuringHighMemoryScenePreparing

    init(
        highMemoryPreflight: any TuringHighMemoryScenePreparing =
            TuringHighMemoryPreflightCoordinator.shared
    ) {
        self.highMemoryPreflight = highMemoryPreflight
    }

    func make(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterRenderSession {
        TuringCharacterQwenRenderSession(
            runtime: runtime,
            runID: runID,
            highMemoryPreflight: highMemoryPreflight
        )
    }

    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterStreamingRenderSession {
        TuringCharacterQwenRenderSession(
            runtime: runtime,
            runID: runID,
            highMemoryPreflight: highMemoryPreflight
        )
    }
}

actor TuringCharacterQwenRenderSession:
    TuringCharacterRenderSession,
    TuringCharacterStreamingRenderSession
{
    private let runtime: TuringCharacterRuntimeDefinition
    private let runID: String
    private let resources: TuringBaseCloneRuntimeResources
    private let arbiter: TuringQwenCharacterPoolArbiter
    private let highMemoryPreflight:
        any TuringHighMemoryScenePreparing

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
    private var streamingQueue: TuringQwenOpenSegmentQueue?
    private var streamingTask:
        Task<TuringQwenNativeFreshInstanceRunReport, Error>?
    private var streamingState: TuringCharacterStreamingRenderState?
    private var streamingInputSealed = false

    init(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String,
        resources: TuringBaseCloneRuntimeResources =
            TuringBaseCloneRuntimeResources(),
        arbiter: TuringQwenCharacterPoolArbiter = .shared,
        highMemoryPreflight: any TuringHighMemoryScenePreparing =
            TuringHighMemoryPreflightCoordinator.shared
    ) {
        self.runtime = runtime
        self.runID = runID
        self.resources = resources
        self.arbiter = arbiter
        self.highMemoryPreflight = highMemoryPreflight
    }

    func begin() async throws {
        guard started == false else { return }

        try await highMemoryPreflight.prepareForTuringHighMemoryRun(
            runID: runID
        )

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
        let requests = makeRequests(stage, profile: profile)

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

    func begin(
        onStarted: @escaping @Sendable (Int) async -> Void,
        onFinished: @escaping @Sendable (
            Int,
            TuringComputeGapGeneratedAudio
        ) async throws -> Void,
        onSkipped: @escaping @Sendable (Int, String) async -> Void
    ) async throws {
        try await begin()
        guard streamingTask == nil,
              let scheduler,
              let stagedModel else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming render session is already active or unavailable."
            )
        }

        let queue = TuringQwenOpenSegmentQueue()
        let state = TuringCharacterStreamingRenderState()
        let streamRunID = runID
        let skipSegmentFailures = runtime.qwen.skipSegmentFailures
        streamingQueue = queue
        streamingState = state
        streamingInputSealed = false

        streamingTask = Task.detached(priority: .userInitiated) {
            do {
                let report = try await scheduler.runOpenQueue(
                    queue,
                    runID: streamRunID,
                    modelRoot: stagedModel,
                    skipSegmentFailures: skipSegmentFailures,
                    onSegmentStarted: { _, segmentIndex in
                        await onStarted(segmentIndex)
                    },
                    onSegmentDecoded: { result in
                        let audio = TuringComputeGapGeneratedAudio(
                            segmentIndex: result.segmentIndex,
                            samples: result.audio.samples,
                            sampleRate: Double(result.audio.sampleRate),
                            channelCount: 1
                        )
                        try await onFinished(result.segmentIndex, audio)
                        await state.recordPublished(result.segmentIndex)
                    },
                    onSegmentSkipped: { skipped in
                        await onSkipped(
                            skipped.segmentIndex,
                            skipped.errorDescription
                        )
                        await state.recordSkipped(
                            skipped.segmentIndex,
                            reason: skipped.errorDescription
                        )
                    }
                )
                report.log()
                await state.schedulerFinished()
                return report
            } catch {
                await state.fail(reason: error.localizedDescription)
                throw error
            }
        }

        print("""
        [TuringScriptVoiceStreaming] render session opened
          runID: \(runID)
          freshInstanceCount: 2
          decoderConcurrency: 1
          inputQueueSealed: false
        """)
    }

    func submit(_ stage: TuringCommittedSpeechStage) async throws {
        guard streamingInputSealed == false,
              let streamingQueue,
              let streamingState,
              let profile else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming render session cannot accept a batch."
            )
        }
        guard stage.globalRange.count == stage.segments.count,
              stage.segments.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Committed stage \(stage.stageID) has an invalid segment range."
            )
        }

        let requests = makeRequests(stage, profile: profile)
        try await streamingState.register(stage.globalRange)
        do {
            try await streamingQueue.append(requests)
        } catch {
            await streamingState.fail(reason: error.localizedDescription)
            throw error
        }
        let depth = await streamingQueue.depth()
        print("""
        [TuringScriptVoiceStreaming] submitted
          runID: \(runID)
          stageID: \(stage.stageID)
          kind: \(stage.kind.rawValue)
          globalRange: \(stage.globalRange)
          openQueueDepth: \(depth)
        """)
    }

    func waitUntilPublished(throughExclusiveIndex: Int) async throws {
        guard let streamingState else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming render session is not active."
            )
        }
        try await streamingState.waitUntilResolved(
            throughExclusiveIndex: throughExclusiveIndex
        )
    }

    func sealInput(finalExpectedSegmentCount: Int) async {
        guard streamingInputSealed == false else { return }
        streamingInputSealed = true
        await streamingState?.seal(expectedSegmentCount: finalExpectedSegmentCount)
        await streamingQueue?.seal()
        print("""
        [TuringScriptVoiceStreaming] input sealed
          runID: \(runID)
          finalExpectedSegmentCount: \(finalExpectedSegmentCount)
        """)
    }

    func waitUntilPublished() async throws -> TuringCharacterRenderReport {
        guard streamingInputSealed,
              let streamingTask,
              let streamingState else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming input must be sealed before final publication wait."
            )
        }
        _ = try await streamingTask.value
        return try await streamingState.finalReport()
    }

    func finish(reason: String) async {
        guard finished == false else { return }
        if streamingTask != nil, streamingInputSealed == false {
            let registeredUpperBound: Int
            if let streamingState {
                registeredUpperBound = await streamingState
                    .registeredUpperBound()
            } else {
                registeredUpperBound = 0
            }
            await sealInput(
                finalExpectedSegmentCount: registeredUpperBound
            )
        }
        _ = try? await streamingTask?.value
        finished = true
        await pool?.unloadAll(
            reason: "turingFlow.\(runtime.characterID).\(reason).\(runID)"
        )
        pool = nil
        scheduler = nil
        profile = nil
        stagedModel = nil
        streamingQueue = nil
        streamingTask = nil
        streamingState = nil
        await releaseOwner(reason: reason)
    }

    func cancel(reason: String) async {
        await streamingQueue?.cancel(reason: reason)
        streamingTask?.cancel()
        await finish(reason: "cancel.\(reason)")
    }

    private func makeRequests(
        _ stage: TuringCommittedSpeechStage,
        profile: TuringQwenNativeCloneProfile
    ) -> [TuringQwenNativeBaseCloneSegmentRequest] {
        zip(stage.globalRange, stage.segments).map { globalIndex, segment in
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
                generationQualityPolicy: runtime.qwen.generationQualityPolicy
            )
        }
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

private actor TuringCharacterStreamingRenderState {
    private var registeredIndices = Set<Int>()
    private var publishedIndices = Set<Int>()
    private var skippedReasons: [Int: String] = [:]
    private var expectedSegmentCount: Int?
    private var failureReason: String?
    private var schedulerDidFinish = false
    private var waiters: [
        (throughExclusiveIndex: Int, continuation: CheckedContinuation<Void, Error>)
    ] = []

    func register(_ range: Range<Int>) throws {
        for index in range {
            guard registeredIndices.insert(index).inserted else {
                throw TuringRuntimeError.invalidConfig(
                    "Duplicate streaming segment index \(index)."
                )
            }
        }
    }

    func recordPublished(_ index: Int) {
        publishedIndices.insert(index)
        skippedReasons.removeValue(forKey: index)
        reconcileWaiters()
    }

    func recordSkipped(_ index: Int, reason: String) {
        guard publishedIndices.contains(index) == false else { return }
        skippedReasons[index] = reason
        reconcileWaiters()
    }

    func waitUntilResolved(throughExclusiveIndex: Int) async throws {
        if let failureReason {
            throw Self.error(failureReason)
        }
        if isResolved(throughExclusiveIndex: throughExclusiveIndex) {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((throughExclusiveIndex, continuation))
        }
    }

    func seal(expectedSegmentCount: Int) {
        self.expectedSegmentCount = expectedSegmentCount
    }

    func schedulerFinished() {
        schedulerDidFinish = true
        reconcileWaiters()
    }

    func fail(reason: String) {
        guard failureReason == nil else { return }
        failureReason = reason
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach { $0.continuation.resume(throwing: Self.error(reason)) }
    }

    func registeredUpperBound() -> Int {
        (registeredIndices.max() ?? -1) + 1
    }

    func finalReport() throws -> TuringCharacterRenderReport {
        if let failureReason {
            throw Self.error(failureReason)
        }
        guard schedulerDidFinish, let expectedSegmentCount else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming scheduler has not finished."
            )
        }
        let expectedIndices = Set(0..<expectedSegmentCount)
        guard registeredIndices == expectedIndices,
              publishedIndices.union(skippedReasons.keys) == expectedIndices else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming scheduler did not resolve its exact sealed index set."
            )
        }
        return TuringCharacterRenderReport(
            expectedSegmentCount: expectedSegmentCount,
            successfulSegmentIndices: publishedIndices,
            skippedSegmentReasons: skippedReasons
        )
    }

    private func isResolved(throughExclusiveIndex: Int) -> Bool {
        guard throughExclusiveIndex > 0 else { return true }
        return (0..<throughExclusiveIndex).allSatisfy {
            publishedIndices.contains($0) || skippedReasons[$0] != nil
        }
    }

    private func reconcileWaiters() {
        guard failureReason == nil else { return }
        var remaining: [
            (throughExclusiveIndex: Int, continuation: CheckedContinuation<Void, Error>)
        ] = []
        for waiter in waiters {
            if isResolved(throughExclusiveIndex: waiter.throughExclusiveIndex) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private static func error(_ reason: String) -> NSError {
        NSError(
            domain: "TuringCharacterStreamingRenderSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
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
