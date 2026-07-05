#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation
import AVFoundation
import TuringQwenNative

enum TuringNativeQwenRunResult: Sendable {
    case succeeded(String)
    case failed(String)

    var pickerStatus: String {
        switch self {
        case .succeeded(let message):
            return message
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
}

@MainActor
private final class TuringParallelPerfGapAudioBridge: @unchecked Sendable {
    private let coordinator: TuringComputeGapAudioCoordinator

    init(
        coordinator: TuringComputeGapAudioCoordinator
    ) {
        self.coordinator = coordinator
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async {
        await coordinator.beginRun(
            runID: runID,
            expectedSegmentCount: expectedSegmentCount
        )
    }

    func qwenComputeStarted(
        segmentIndex: Int
    ) async {
        await coordinator.qwenComputeStarted(segmentIndex: segmentIndex)
    }

    func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async {
        await coordinator.qwenComputeFinished(
            segmentIndex: segmentIndex,
            audio: audio
        )
    }

    func qwenComputeAllFinished() async {
        await coordinator.qwenComputeAllFinished()
    }

    func waitUntilPlaybackFinished() async {
        await coordinator.waitUntilPlaybackFinished()
    }

    func runCancelled(
        reason: String
    ) async {
        await coordinator.runCancelled(reason: reason)
    }
}

private actor TuringFirstSegmentReadyNotifier {
    private let onFirstSegmentReady: (@MainActor @Sendable () async -> Void)?
    private var didNotify = false

    init(
        onFirstSegmentReady: (@MainActor @Sendable () async -> Void)?
    ) {
        self.onFirstSegmentReady = onFirstSegmentReady
    }

    func notifyIfNeeded(segmentIndex: Int) async {
        guard segmentIndex == 0,
              didNotify == false else {
            return
        }
        didNotify = true
        await onFirstSegmentReady?()
    }
}

enum TuringNativeQwenHelloWorldCanary {
    private static let expectedModelFolderName = "Qwen3-TTS-12Hz-1.7B-Base-4bit"
    private static let activeModelID = "qwen3-tts-12hz-1.7b-base-4bit"
    private static let activeQuantization = "4bit"
    private static let activeRuntimeMode = "baseClone"
    private static let activeWeightBackend = "mlx4bit"
    private static let memoryDiagnosticsEnvKey = "TURING_QWEN_MEMORY_DIAGNOSTICS"
    private static let foundationGuardrailAutoResponse = "No man. You can't say that."
    private static let activeParallelQwenLaneCount = 2
    private static let activeParallelQwenMode = "freshInstances"

    static func run(
        preset: TuringNativeQwenVoiceDesignCanaryPreset = .bigMikeShortDynamic
    ) async -> TuringNativeQwenRunResult {
        let input = preset.input
        var engine: TuringQwenNativeBaseCloneEngine?

        do {
            let phase1Segments = try await resolvePhase1FoundationSegmentsIfNeeded(
                preset: preset
            )

            print("""
            [TuringQwenNativeBaseClone] requested
              implementation: in_repo_turing_qwen_native
              source: QwenLM/Qwen3-TTS Base clone architecture port
              preset: \(preset.rawValue)
              modelID: \(activeModelID)
              runtimeMode: \(activeRuntimeMode)
              quantization: \(activeQuantization)
              weightBackend: \(activeWeightBackend)
              voiceID: big_mike_base_clone_v1
              textUTF16: \(input.spokenText.utf16.count)
              runtimeRefAudioUsed: false
              runtimeRefTextUsed: false
              precomputedCloneArtifacts: true
              fixtureRowsUsed: false
              episodePickerButton: true
              prologueBypassed: true
              turingAudioCacheBypassed: true
              thirdPartyQwenFrameworkBypassed: true
              runtimeNetworkAllowed: false
            """)

            let modelRoot = try locateBundledBaseCloneModel()
            let cloneProfile = try loadBundledBigMikeCloneProfile()

            logMemoryBudgetIfEnabled(
                label: "beforeQwenStage",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            let stagedRoot = try stageWritableModel(from: modelRoot)
            logMemoryBudgetIfEnabled(
                label: "afterQwenStage",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            logMemoryBudgetIfEnabled(
                label: "beforeQwenGenerate",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            if preset.isLongform {
                if let phase1Segments {
                    try await runLongform(
                        preset: preset,
                        cloneProfile: cloneProfile,
                        stagedRoot: stagedRoot,
                        segments: phase1Segments,
                        runID: "phase1FoundationVoiceScript"
                    )
                } else {
                    try await runLongform(
                        preset: preset,
                        cloneProfile: cloneProfile,
                        stagedRoot: stagedRoot
                    )
                }
            } else {
                logMemoryBudgetIfEnabled(
                    label: "beforeQwenLoad",
                    activeQwenModelID: activeModelID,
                    quantization: activeQuantization
                )
                let loadedEngine = try TuringQwenNativeBaseCloneEngine(
                    modelRoot: stagedRoot,
                    trace: .stdout(prefix: "[TuringQwenNativeBaseClone]")
                )
                engine = loadedEngine
                logMemoryBudgetIfEnabled(
                    label: "afterQwenLoad",
                    activeQwenModelID: activeModelID,
                    quantization: activeQuantization
                )

                let audio = try await renderBaseCloneSegment(
                    preset: preset,
                    cloneProfile: cloneProfile,
                    engine: loadedEngine,
                    segment: input.spokenText,
                    segmentIndex: 0
                )

                let processedSamples = await TuringQwenOutputPostProcessor.processSamplesForPlayback(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate,
                    segmentIndex: 0,
                    reason: "directMemoryPlayer.\(preset.rawValue)"
                )

                try await TuringQwenNativeMemoryPlayer.shared.play(
                    samples: processedSamples,
                    sampleRate: audio.sampleRate
                )

                await loadedEngine.releaseResidentState(
                    reason: "episodePickerRunFinished.\(preset.rawValue)",
                    logMemorySnapshot: shouldLogMemoryDiagnostics
                )
                engine = nil
            }

            logMemoryBudgetIfEnabled(
                label: "afterQwenGenerate",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")

            print("[TuringQwenNativeBaseClone] playback finished")
            return .succeeded("Finished \(preset.rawValue)")
        } catch {
            if let engine {
                await engine.releaseResidentState(
                    reason: "episodePickerRunFailed.\(preset.rawValue)",
                    logMemorySnapshot: shouldLogMemoryDiagnostics
                )
            }
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")

            print("""
            [TuringQwenNativeBaseClone] failed
              error: \(error.localizedDescription)
            """)
            return .failed(error.localizedDescription)
        }
    }

    private static var shouldLogMemoryDiagnostics: Bool {
        let value = ProcessInfo.processInfo.environment[memoryDiagnosticsEnvKey] ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    private static func logMemoryBudgetIfEnabled(
        label: String,
        activeQwenModelID: String? = nil,
        quantization: String? = nil
    ) {
        guard shouldLogMemoryDiagnostics else {
            return
        }

        TuringMemoryBudgetProbe.log(
            label: label,
            activeQwenModelID: activeQwenModelID,
            quantization: quantization
        )
    }

    static func runBaseCloneRuntimePreflight(
        preset: TuringNativeQwenVoiceDesignCanaryPreset = .bigMikeShortDynamic
    ) async -> TuringNativeQwenRunResult {
        let input = preset.input

        do {
            print("""
            [TuringQwenNativeBaseClone] runtime preflight requested
              implementation: in_repo_turing_qwen_native
              preset: \(preset.rawValue)
              modelID: \(activeModelID)
              runtimeMode: \(activeRuntimeMode)
              quantization: \(activeQuantization)
              voiceID: big_mike_base_clone_v1
              textUTF16: \(input.spokenText.utf16.count)
              runtimeRefAudioUsed: false
              runtimeRefTextUsed: false
              precomputedCloneArtifacts: true
              modelForwardStarted: false
              playbackStarted: false
              episodePickerButton: true
            """)

            let modelRoot = try locateBundledBaseCloneModel()
            let cloneProfile = try loadBundledBigMikeCloneProfile()

            TuringMemoryBudgetProbe.log(
                label: "beforeQwenPreflightStage",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            let stagedRoot = try stageWritableModel(from: modelRoot)
            TuringMemoryBudgetProbe.log(
                label: "afterQwenPreflightStage",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            let engine = try TuringQwenNativeBaseCloneEngine(
                modelRoot: stagedRoot,
                trace: .stdout(prefix: "[TuringQwenNativeBaseClone]")
            )
            let prompt = TuringQwenNativeBaseClonePrompt(
                text: input.spokenText,
                language: input.language,
                cloneProfile: cloneProfile
            )
            let report = try await engine.preflightBaseClone(prompt: prompt)

            print("""
            [TuringQwenNativeBaseClone] runtime preflight finished
              status: passed
              voiceID: \(report.voiceID)
              variantID: \(report.variantID)
              targetTokenCount: \(report.targetTokenCount)
              referenceRows: \(report.referenceRowCount)
              codebookCount: \(report.codebookCount)
              speakerEmbeddingShape: [\(report.speakerEmbeddingCount)]
              modelForwardStarted: false
              playbackStarted: false
            """)

            TuringMemoryBudgetProbe.log(label: "afterQwenPreflight")
            TuringMemoryBudgetProbe.log(label: "afterTransientCleanup")
        return .succeeded("Preflight passed: Big Mike clone artifacts are ready")
        } catch {
            TuringMemoryBudgetProbe.log(label: "afterTransientCleanup")

            print("""
            [TuringQwenNativeBaseClone] runtime preflight failed
              error: \(error.localizedDescription)
            """)
            return .failed(error.localizedDescription)
        }
    }

    static func runDialogueSegments(
        _ segments: [TuringSpeechSegment],
        runID: String,
        source: String,
        onFirstSegmentReady: (@MainActor @Sendable () async -> Void)? = nil
    ) async -> TuringNativeQwenRunResult {
        do {
            let spokenSegments = segments.map(\.text)
            guard spokenSegments.isEmpty == false else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Dialogue response did not contain speech segments."
                )
            }

            print("""
            [TuringNativeQwenSpeech] rendering started
              runID: \(runID)
              source: \(source)
              segmentCount: \(segments.count)
              voiceID: big_mike_base_clone_v1
              modelID: \(activeModelID)
              quantization: \(activeQuantization)
              parallelQwenLanes: \(activeParallelQwenLaneCount)
              parallelQwenMode: \(activeParallelQwenMode)
            """)

            let modelRoot = try locateBundledBaseCloneModel()
            let cloneProfile = try loadBundledBigMikeCloneProfile()
            let stagedRoot = try stageWritableModel(from: modelRoot)

            for (index, segment) in segments.enumerated() {
                print("""
                [TuringNativeQwenSpeech] segment render started
                  segmentIndex: \(index)
                  textUTF16: \(segment.text.utf16.count)
                  emotion: \(segment.emotion)
                  text: \(segment.text)
                """)
            }

            try await runLongform(
                preset: .phase1FoundationVoiceScript,
                cloneProfile: cloneProfile,
                stagedRoot: stagedRoot,
                segments: spokenSegments,
                runID: runID,
                onFirstSegmentReady: onFirstSegmentReady
            )

            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")

            return .succeeded("Finished \(runID)")
        } catch {
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")

            print("""
            [TuringNativeQwenSpeech] rendering failed
              runID: \(runID)
              error: \(error.localizedDescription)
            """)
            return .failed(error.localizedDescription)
        }
    }

    static func runParallelPerf(
        laneCount: Int
    ) async -> TuringNativeQwenRunResult {
        do {
            let report = try await runParallelPerfReport(
                laneCount: laneCount,
                runID: "parallelPerf.\(laneCount)Lane"
            )
            return .succeeded(
                "Parallel \(report.laneCountActive) lane RTF \(String(format: "%.2f", report.aggregateRealTimeFactor))"
            )
        } catch {
            print("""
            [TuringQwenParallel] failed
              laneCountRequested: \(laneCount)
              error: \(error.localizedDescription)
            """)
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")
            return .failed(error.localizedDescription)
        }
    }

    static func runParallelPerfCompare() async -> TuringNativeQwenRunResult {
        do {
            let oneLane = try await runParallelPerfReport(
                laneCount: 1,
                runID: "parallelPerf.compare.1Lane"
            )
            let twoLane = try await runParallelPerfReport(
                laneCount: 2,
                runID: "parallelPerf.compare.2Lanes",
                singleLaneBaselineRTF: oneLane.aggregateRealTimeFactor
            )
            let improvement: Double
            if oneLane.aggregateRealTimeFactor > 0 {
                improvement = (oneLane.aggregateRealTimeFactor - twoLane.aggregateRealTimeFactor) /
                    oneLane.aggregateRealTimeFactor
            } else {
                improvement = 0
            }

            print("""
            [TuringQwenParallel] compare finished
              oneLaneAggregateRealTimeFactor: \(String(format: "%.3f", oneLane.aggregateRealTimeFactor))
              twoLaneAggregateRealTimeFactor: \(String(format: "%.3f", twoLane.aggregateRealTimeFactor))
              improvementPercent: \(String(format: "%.1f", improvement * 100))
              keepTwoLaneCandidate: \(improvement >= 0.25)
            """)

            return .succeeded(
                "1 lane \(String(format: "%.2f", oneLane.aggregateRealTimeFactor))x, 2 lanes \(String(format: "%.2f", twoLane.aggregateRealTimeFactor))x"
            )
        } catch {
            print("""
            [TuringQwenParallel] compare failed
              error: \(error.localizedDescription)
            """)
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")
            return .failed(error.localizedDescription)
        }
    }

    private static func runParallelPerfReport(
        laneCount: Int,
        runID: String,
        singleLaneBaselineRTF: Double? = nil
    ) async throws -> TuringQwenNativeParallelPerfReport {
        let preset = TuringNativeQwenVoiceDesignCanaryPreset.bigMikeBroadcastLongformDynamic
        let segments = Array(preset.segments.prefix(6))
        let laneCountRequested = max(1, laneCount)

        print("""
        [TuringQwenParallel] canary requested
          runID: \(runID)
          laneCountRequested: \(laneCountRequested)
          segmentCount: \(segments.count)
          modelID: \(activeModelID)
          quantization: \(activeQuantization)
          parallelQwenLanes: \(laneCountRequested)
          parallelQwenMode: inProcessSharedWeightsDefaultStream
          parallelQwenEnabledForDebugOnly: true
        """)

        let modelRoot = try locateBundledBaseCloneModel()
        let cloneProfile = try loadBundledBigMikeCloneProfile()
        logMemoryBudgetIfEnabled(
            label: "beforeQwenParallelStage",
            activeQwenModelID: activeModelID,
            quantization: activeQuantization
        )
        let stagedRoot = try stageWritableModel(from: modelRoot)
        logMemoryBudgetIfEnabled(
            label: "afterQwenParallelStage",
            activeQwenModelID: activeModelID,
            quantization: activeQuantization
        )

        let requests = segments.enumerated().map { index, text in
            TuringQwenNativeBaseCloneSegmentRequest(
                segmentIndex: index,
                text: text,
                language: preset.input.language,
                cloneProfile: cloneProfile,
                maxNewRows: preset.maxNewTokens(for: text),
                performanceMode: preset.performanceMode,
                referenceRowLimit: preset.referenceRowLimit,
                referenceWindowStrategy: preset.referenceWindowStrategy
            )
        }

        let gapAudio = try await MainActor.run {
            try TuringParallelPerfGapAudioBridge(
                coordinator: TuringComputeGapAudioCoordinator.makeBigMikeCoordinator()
            )
        }
        await gapAudio.beginRun(
            runID: runID,
            expectedSegmentCount: requests.count
        )

        let lanePool = try TuringQwenNativeParallelLanePool(
            modelRoot: stagedRoot,
            laneCountRequested: laneCountRequested
        )
        let scheduler = TuringQwenNativeParallelScheduler(lanePool: lanePool)

        do {
            let report = try await scheduler.renderSegments(
                requests,
                runID: runID,
                onSegmentStarted: { _, segmentIndex in
                    await gapAudio.qwenComputeStarted(segmentIndex: segmentIndex)
                },
                onSegmentFinished: { generated in
                    await gapAudio.qwenComputeFinished(
                        segmentIndex: generated.segmentIndex,
                        audio: TuringComputeGapGeneratedAudio(
                            segmentIndex: generated.segmentIndex,
                            samples: generated.audio.samples,
                            sampleRate: Double(generated.audio.sampleRate),
                            channelCount: 1
                        )
                    )
                }
            )
            report.log(singleLaneBaselineRTF: singleLaneBaselineRTF)
            await gapAudio.qwenComputeAllFinished()
            await gapAudio.waitUntilPlaybackFinished()
            await lanePool.releaseResidentResources(reason: "parallelPerfFinished.\(runID)")
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")
            return report
        } catch {
            await gapAudio.runCancelled(
                reason: "parallelPerfFailed.\(String(describing: error))"
            )
            await lanePool.releaseResidentResources(reason: "parallelPerfFailed.\(runID)")
            throw error
        }
    }

    static func runLongformVoiceScriptResource(
        resourcePath: String,
        requestID: String,
        debugLabel: String
    ) async -> TuringNativeQwenRunResult {
        do {
            let url = try TuringResourceLoader.resourceURL(
                resourcePath: resourcePath
            )
            let sourceText = try String(contentsOf: url, encoding: .utf8)
            let request = TuringLongformVoiceScriptRequest(
                requestID: requestID,
                sourceText: sourceText,
                speakerID: "big_mike",
                voiceID: "big_mike_base_clone_v1",
                defaultEmotion: "controlled, grave, documentary",
                playbackTarget: TuringPlaybackTarget(id: "storyEpisodePicker"),
                debugLabel: debugLabel
            )

            print("""
            [TuringPhase1Audiobook] requested
              requestID: \(request.requestID)
              debugLabel: \(debugLabel)
              sourceUTF16: \(request.sourceText.utf16.count)
              voiceID: \(request.voiceID)
            """)

            let runner = TuringVoiceScriptLongformRunner()
            let sourcePlan = try runner.makeSourcePlan(request: request)

            print("""
            [TuringPhase1Audiobook] rolling window started
              requestID: \(request.requestID)
              sectionCount: \(sourcePlan.sections.count)
              parallelQwenLanes: \(activeParallelQwenLaneCount)
              parallelQwenMode: \(activeParallelQwenMode)
              foundationRollingWindow: true
              foundationWindow: currentPlusNext
              playbackOwner: TuringComputeGapAudioCoordinator
            """)

            let modelRoot = try locateBundledBaseCloneModel()
            let cloneProfile = try loadBundledBigMikeCloneProfile()
            let stagedRoot = try stageWritableModel(from: modelRoot)

            try await runAudiobookSections(
                preset: .phase1FoundationVoiceScript,
                cloneProfile: cloneProfile,
                stagedRoot: stagedRoot,
                runner: runner,
                request: request,
                sourcePlan: sourcePlan,
                runID: request.requestID
            )

            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")

            print("""
            [TuringPhase1Audiobook] finished
              requestID: \(request.requestID)
              parallelQwenLanes: \(activeParallelQwenLaneCount)
            """)

            return .succeeded("Finished \(debugLabel)")
        } catch {
            logMemoryBudgetIfEnabled(label: "afterTransientCleanup")
            logMemoryBudgetIfEnabled(label: "afterQwenUnload")

            print("""
            [TuringPhase1Audiobook] failed
              requestID: \(requestID)
              error: \(error.localizedDescription)
            """)
            return .failed(error.localizedDescription)
        }
    }

    private static func runLongform(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        stagedRoot: URL
    ) async throws {
        try await runLongform(
            preset: preset,
            cloneProfile: cloneProfile,
            stagedRoot: stagedRoot,
            segments: preset.segments,
            runID: "bigMikeBaseCloneLongform"
        )
    }

    private static func runAudiobookSections(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        stagedRoot: URL,
        runner: TuringVoiceScriptLongformRunner,
        request: TuringLongformVoiceScriptRequest,
        sourcePlan: TuringAudiobookSourcePlan,
        runID: String
    ) async throws {
        let gapAudio = try await MainActor.run {
            try TuringParallelPerfGapAudioBridge(
                coordinator: TuringComputeGapAudioCoordinator.makeBigMikeCoordinator()
            )
        }

        await gapAudio.beginRun(
            runID: runID,
            expectedSegmentCount: nil
        )

        let freshPool = try TuringQwenNativeGenerationSchedulerFactory.makeFresh2Pool()
        try await freshPool.warmLoadExactlyRequestedInstances(
            modelRoot: stagedRoot,
            cloneProfile: cloneProfile,
            variantID: cloneProfile.defaultVariantID,
            performanceMode: preset.performanceMode
        )
        logMemoryBudgetIfEnabled(
            label: "afterQwenFresh2WarmLoad",
            activeQwenModelID: activeModelID,
            quantization: activeQuantization
        )
        let scheduler = TuringQwenNativeGenerationSchedulerFactory.makeFresh2Scheduler(
            instancePool: freshPool
        )
        var renderedSegmentCount = 0
        var currentSectionIndex = 0
        var currentTask: Task<TuringAudiobookSectionSegmentationResult, Error>?
        var nextTask: Task<TuringAudiobookSectionSegmentationResult, Error>?

        func makeSectionTask(
            _ sectionIndex: Int
        ) -> Task<TuringAudiobookSectionSegmentationResult, Error>? {
            guard sourcePlan.sections.indices.contains(sectionIndex) else {
                return nil
            }
            let section = sourcePlan.sections[sectionIndex]
            return Task.detached(priority: .userInitiated) {
                try await runner.prepareSection(
                    section,
                    in: sourcePlan,
                    request: request
                )
            }
        }

        do {
            currentTask = makeSectionTask(0)

            while let task = currentTask {
                let sectionResult = try await task.value
                let nextSectionIndex = currentSectionIndex + 1
                nextTask = makeSectionTask(nextSectionIndex)

                print("""
                [TuringPhase1Audiobook] section parallel render began
                  sectionIndex: \(sectionResult.section.index)
                  segmentCount: \(sectionResult.segments.count)
                  nextSectionPreparing: \(nextTask == nil ? "false" : "true")
                  parallelQwenLanes: \(activeParallelQwenLaneCount)
                """)

                let sectionTexts = sectionResult.segments.map(\.spokenText)
                let requests = makeParallelBaseCloneRequests(
                    preset: preset,
                    cloneProfile: cloneProfile,
                    segments: sectionTexts,
                    startingSegmentIndex: renderedSegmentCount
                )
                let report = try await renderFreshBaseCloneRequests(
                    requests,
                    scheduler: scheduler,
                    gapAudio: gapAudio,
                    runID: "\(runID).section\(sectionResult.section.index)"
                )
                renderedSegmentCount += sectionTexts.count
                logMemoryBudgetIfEnabled(
                    label: "afterQwenFresh2SectionRenderBeforeUnload",
                    activeQwenModelID: activeModelID,
                    quantization: activeQuantization
                )

                print("""
                [TuringPhase1Audiobook] section parallel render finished
                  sectionIndex: \(sectionResult.section.index)
                  renderedSegmentCount: \(renderedSegmentCount)
                  aggregateRealTimeFactor: \(String(format: "%.3f", report.aggregateRealTimeFactor))
                """)

                currentSectionIndex = nextSectionIndex
                currentTask = nextTask
                nextTask = nil
            }

            guard renderedSegmentCount > 0 else {
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Phase 1 audiobook produced no spoken segments."
                )
            }

            await gapAudio.qwenComputeAllFinished()
            await gapAudio.waitUntilPlaybackFinished()
            await freshPool.unloadAll(reason: "audiobookFinished.\(runID)")
        } catch {
            currentTask?.cancel()
            nextTask?.cancel()
            await gapAudio.runCancelled(
                reason: "audiobookFailed.\(String(describing: error))"
            )
            await freshPool.unloadAll(reason: "audiobookFailed.\(runID)")
            throw error
        }
    }

    private static func resolvePhase1FoundationSegmentsIfNeeded(
        preset: TuringNativeQwenVoiceDesignCanaryPreset
    ) async throws -> [String]? {
        guard preset == .phase1FoundationVoiceScript else {
            return nil
        }

        let input = preset.input
        let requestID = "story.picker.phase1.voiceScript.001"
        let emotion = "urgent, controlled"
        let segmentation = TuringVoiceScriptFoundationSegmentationService()

        let report: TuringVoiceScriptFoundationSegmentationReport
        do {
            report = try await segmentation.segmentExactSpeech(
                sourceText: input.spokenText,
                requestID: requestID,
                emotion: emotion
            )
        } catch where isFoundationGuardrailError(error) {
            print("""
            [TuringPhase1] Foundation guardrails triggered
              requestID: \(requestID)
              autoTuringResponse: \(foundationGuardrailAutoResponse)
              qwenWillGenerateAutoResponse: true
            """)
            return [foundationGuardrailAutoResponse]
        }

        let segments = report.segments.map(\.spokenText)

        print("""
        [TuringPhase1] voiceScript approved for Qwen
          requestID: \(requestID)
          segmentCount: \(segments.count)
          exactCoverage: \(report.exactCoveragePassed ? "passed" : "mismatchLogged")
          renderer: in_repo_turing_qwen_native_base_clone
          voiceID: big_mike_base_clone_v1
          modelID: \(activeModelID)
          quantization: \(activeQuantization)
          qwenSequentialPerSegment: true
        """)

        return segments
    }

    private static func isFoundationGuardrailError(
        _ error: Error
    ) -> Bool {
        let description = [
            error.localizedDescription,
            String(describing: error)
        ]
        .joined(separator: " ")
        .lowercased()

        return description.contains("guardrail")
            || description.contains("safety")
            || description.contains("safe")
            || description.contains("policy")
            || description.contains("not allowed")
    }

    private static func runLongform(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        stagedRoot: URL,
        segments: [String],
        runID: String,
        onFirstSegmentReady: (@MainActor @Sendable () async -> Void)? = nil
    ) async throws {
        guard segments.isEmpty == false else {
            print("""
            [TuringQwenNativeBaseCloneLongform] skipped
              reason: noSegments
            """)
            return
        }

        print("""
        [TuringQwenNativeBaseCloneLongform] started
          runID: \(runID)
          segmentCount: \(segments.count)
          modelID: \(activeModelID)
          runtimeMode: \(activeRuntimeMode)
          quantization: \(activeQuantization)
          weightBackend: \(activeWeightBackend)
          computeAhead: true
          parallelQwenLanes: \(activeParallelQwenLaneCount)
          parallelQwenMode: \(activeParallelQwenMode)
        """)

        let gapAudio = try await MainActor.run {
            try TuringParallelPerfGapAudioBridge(
                coordinator: TuringComputeGapAudioCoordinator.makeBigMikeCoordinator()
            )
        }

        await gapAudio.beginRun(
            runID: runID,
            expectedSegmentCount: segments.count
        )

        let freshPool = try TuringQwenNativeGenerationSchedulerFactory.makeFresh2Pool()
        try await freshPool.warmLoadExactlyRequestedInstances(
            modelRoot: stagedRoot,
            cloneProfile: cloneProfile,
            variantID: cloneProfile.defaultVariantID,
            performanceMode: preset.performanceMode
        )
        logMemoryBudgetIfEnabled(
            label: "afterQwenFresh2WarmLoad",
            activeQwenModelID: activeModelID,
            quantization: activeQuantization
        )
        let scheduler = TuringQwenNativeGenerationSchedulerFactory.makeFresh2Scheduler(
            instancePool: freshPool
        )
        let requests = makeParallelBaseCloneRequests(
            preset: preset,
            cloneProfile: cloneProfile,
            segments: segments,
            startingSegmentIndex: 0
        )

        do {
            let report = try await renderFreshBaseCloneRequests(
                requests,
                scheduler: scheduler,
                gapAudio: gapAudio,
                runID: runID,
                onFirstSegmentReady: onFirstSegmentReady
            )
            logMemoryBudgetIfEnabled(
                label: "afterQwenFresh2RenderBeforeUnload",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            await gapAudio.qwenComputeAllFinished()
            await gapAudio.waitUntilPlaybackFinished()
            await freshPool.unloadAll(reason: "longformFinished.\(runID)")

            print("""
            [TuringQwenNativeBaseCloneLongform] parallel report
              runID: \(runID)
              aggregateRealTimeFactor: \(String(format: "%.3f", report.aggregateRealTimeFactor))
            """)
        } catch {
            await gapAudio.runCancelled(
                reason: "longformFailed.\(String(describing: error))"
            )
            await freshPool.unloadAll(reason: "longformFailed.\(runID)")
            throw error
        }

        print("""
        [TuringQwenNativeBaseCloneLongform] finished
          runID: \(runID)
          segmentCount: \(segments.count)
        """)
    }

    private static func makeParallelBaseCloneRequests(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        segments: [String],
        startingSegmentIndex: Int
    ) -> [TuringQwenNativeBaseCloneSegmentRequest] {
        segments.enumerated().map { offset, text in
            let segmentIndex = startingSegmentIndex + offset
            print("""
            [TuringQwenNativeBaseClone] parallel segment scheduled
              segmentIndex: \(segmentIndex)
              textUTF16: \(text.utf16.count)
              maxNewRows: \(preset.maxNewTokens(for: text))
              parallelQwenLanes: \(activeParallelQwenLaneCount)
              cloneProfileLoaded: true
              profileKind: \(cloneProfile.profileKind)
              referenceRowLimit: \(preset.referenceRowLimit.map(String.init) ?? "full")
              referenceWindowStrategy: \(preset.referenceWindowStrategy.rawValue)
              runtimeRefAudioUsed: false
              fixtureRowsUsed: false
            """)
            return TuringQwenNativeBaseCloneSegmentRequest(
                segmentIndex: segmentIndex,
                text: text,
                language: preset.input.language,
                cloneProfile: cloneProfile,
                maxNewRows: preset.maxNewTokens(for: text),
                performanceMode: preset.performanceMode,
                referenceRowLimit: preset.referenceRowLimit,
                referenceWindowStrategy: preset.referenceWindowStrategy
            )
        }
    }

    private static func renderFreshBaseCloneRequests(
        _ requests: [TuringQwenNativeBaseCloneSegmentRequest],
        scheduler: TuringQwenNativeFreshInstanceScheduler,
        gapAudio: TuringParallelPerfGapAudioBridge,
        runID: String,
        onFirstSegmentReady: (@MainActor @Sendable () async -> Void)? = nil
    ) async throws -> TuringQwenNativeFreshInstanceRunReport {
        let firstSegmentReadyNotifier = TuringFirstSegmentReadyNotifier(
            onFirstSegmentReady: onFirstSegmentReady
        )
        let report = try await scheduler.renderSegments(
            requests,
            runID: runID,
            onSegmentStarted: { _, segmentIndex in
                await gapAudio.qwenComputeStarted(segmentIndex: segmentIndex)
            },
            onSegmentFinished: { generated in
                await firstSegmentReadyNotifier.notifyIfNeeded(
                    segmentIndex: generated.segmentIndex
                )
                await gapAudio.qwenComputeFinished(
                    segmentIndex: generated.segmentIndex,
                    audio: TuringComputeGapGeneratedAudio(
                        segmentIndex: generated.segmentIndex,
                        samples: generated.audio.samples,
                        sampleRate: Double(generated.audio.sampleRate),
                        channelCount: 1
                    )
                )
            }
        )
        report.log()
        return report
    }

    private static func renderBaseCloneSegment(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        engine: TuringQwenNativeBaseCloneEngine,
        segment: String,
        segmentIndex: Int
    ) async throws -> TuringQwenNativeAudio {
        let prompt = TuringQwenNativeBaseClonePrompt(
            text: segment,
            language: preset.input.language,
            cloneProfile: cloneProfile,
            maxNewRows: preset.maxNewTokens(for: segment),
            performanceMode: preset.performanceMode,
            referenceRowLimit: preset.referenceRowLimit,
            referenceWindowStrategy: preset.referenceWindowStrategy
        )

        print("""
        [TuringQwenNativeBaseClone] segment render started
          segmentIndex: \(segmentIndex)
          textUTF16: \(segment.utf16.count)
          maxNewRows: \(preset.maxNewTokens(for: segment))
          cloneProfileLoaded: true
          profileKind: \(cloneProfile.profileKind)
          cloneArtifactsRequired: true
          refTextCharacters: \(cloneProfile.referenceText.utf16.count)
          referenceRowLimit: \(preset.referenceRowLimit.map(String.init) ?? "full")
          referenceWindowStrategy: \(preset.referenceWindowStrategy.rawValue)
          runtimeRefAudioUsed: false
          fixtureRowsUsed: false
        """)

        return try await engine.generateBaseClone(prompt: prompt)
    }

    private static func loadBundledBigMikeCloneProfile() throws -> TuringQwenNativeCloneProfile {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Missing Big Mike Base clone bundled resources."
            )
        }

        return try TuringQwenNativeCloneProfileLoader()
            .loadBigMikeBaseCloneProfile(from: resourceURL)
    }

    private static func locateBundledBaseCloneModel() throws -> URL {
        let candidates = [
            "Turing/Models/Qwen3TTS/\(expectedModelFolderName)",
            "TuringResources/Turing/Models/Qwen3TTS/\(expectedModelFolderName)"
        ]

        for candidate in candidates {
            if let url = Bundle.main.url(forResource: candidate, withExtension: nil) {
                return url
            }
        }

        let availableModels = bundledQwenModelFolderNames()
        let availableSummary = availableModels.isEmpty
            ? "none"
            : availableModels.joined(separator: ", ")

        throw NSError(
            domain: "TuringNativeQwenBaseCloneCanary",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: """
                Bundled Qwen Base 4-bit model not found. Expected \(expectedModelFolderName). Available Qwen model folders: \(availableSummary).
                """
            ]
        )
    }

    private static func bundledQwenModelFolderNames() -> [String] {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: "Turing/Models/Qwen3TTS", withExtension: nil),
            Bundle.main.url(forResource: "TuringResources/Turing/Models/Qwen3TTS", withExtension: nil)
        ]

        for candidate in candidates {
            guard let root = candidate else {
                continue
            }

            guard let contents = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let folderNames = contents.compactMap { url -> String? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return nil
                }

                return url.lastPathComponent
            }

            if !folderNames.isEmpty {
                return folderNames.sorted()
            }
        }

        return []
    }

    private static func stageWritableModel(from source: URL) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let stageContainer = appSupport
            .appendingPathComponent("TuringQwenNativeBaseClone", isDirectory: true)
        let writableModelRoot = stageContainer
            .appendingPathComponent("WritableModel", isDirectory: true)
        let root = writableModelRoot
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)

        try fm.createDirectory(
            at: stageContainer,
            withIntermediateDirectories: true
        )

        try removeLegacyWritableStages(
            stageContainer: stageContainer,
            preserving: writableModelRoot
        )

        if fm.fileExists(atPath: root.path),
           isWritableModelStageUsable(root) {
            try markExcludedFromBackup(root)
            try verifyWritable(root)

            print("""
            [TuringQwenNativeBaseClone] writable stage ready
              source: \(source.path)
              staged: \(root.path)
              writable: true
              reusedExistingStage: true
            """)

            return root
        }

        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }

        try fm.createDirectory(
            at: writableModelRoot,
            withIntermediateDirectories: true
        )

        try fm.copyItem(at: source, to: root)
        try markExcludedFromBackup(root)
        try verifyWritable(root)

        print("""
        [TuringQwenNativeBaseClone] writable stage ready
          source: \(source.path)
          staged: \(root.path)
          writable: true
          reusedExistingStage: false
        """)

        return root
    }

    private static func removeLegacyWritableStages(
        stageContainer: URL,
        preserving writableModelRoot: URL
    ) throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: stageContainer,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents
        where url.standardizedFileURL != writableModelRoot.standardizedFileURL {
            try? fm.removeItem(at: url)
        }
    }

    private static func isWritableModelStageUsable(
        _ root: URL
    ) -> Bool {
        let required = [
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "speech_tokenizer/config.json",
            "speech_tokenizer/model.safetensors"
        ]

        return required.allSatisfy {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent($0).path
            )
        }
    }

    private static func markExcludedFromBackup(
        _ root: URL
    ) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    private static func verifyWritable(
        _ root: URL
    ) throws {
        let probe = root.appendingPathComponent(".write-probe")
        try Data("ok".utf8).write(to: probe)
        try FileManager.default.removeItem(at: probe)
    }
}
#endif
