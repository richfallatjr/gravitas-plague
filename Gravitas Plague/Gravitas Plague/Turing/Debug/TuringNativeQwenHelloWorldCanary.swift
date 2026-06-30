#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation
import AVFoundation
import TuringQwenNative

enum TuringNativeQwenHelloWorldCanary {
    private static let expectedModelFolderName = "Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
    private static let activeModelID = "qwen3-tts-12hz-1.7b-voicedesign-bf16"
    private static let activeQuantization = "bf16"

    private actor LongformRenderReadiness {
        private var ready = false

        func markReady() {
            ready = true
        }

        func isReady() -> Bool {
            ready
        }
    }

    @MainActor
    private static let qwenComputeFillerBridge: BigMikeSegmentGapFillerBridge = {
        var configuration = BigMikeFillerLoopController.Configuration()
        configuration.maxConsecutiveClips = 0
        configuration.maxContinuousSeconds = 90.0
        let loop = BigMikeFillerLoopController(configuration: configuration)
        return BigMikeSegmentGapFillerBridge(loop: loop)
    }()

    @MainActor
    private static func startQwenComputeFiller(segmentIndex: Int, reason: String) {
        print("""
        [TuringQwenNativeCompute] compute filler starting
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
        qwenComputeFillerBridge.segmentEndedWaitingForNext(segmentIndex: segmentIndex)
    }

    @MainActor
    private static func stopQwenComputeFiller(segmentIndex: Int, reason: String) {
        print("""
        [TuringQwenNativeCompute] compute filler stopping
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
        qwenComputeFillerBridge.nextRealSegmentReady(segmentIndex: segmentIndex)
    }

    @MainActor
    private static func startLongformGapFiller(previousSegmentIndex: Int, nextSegmentIndex: Int) {
        print("""
        [TuringQwenNativeLongform] next segment late; filler bridge starting
          previousSegmentIndex: \(previousSegmentIndex)
          nextSegmentIndex: \(nextSegmentIndex)
        """)
        qwenComputeFillerBridge.segmentEndedWaitingForNext(segmentIndex: previousSegmentIndex)
    }

    @MainActor
    private static func stopLongformGapFillerForReadySegment(nextSegmentIndex: Int) {
        print("""
        [TuringQwenNativeLongform] next segment ready; filler bridge stopping
          nextSegmentIndex: \(nextSegmentIndex)
        """)
        qwenComputeFillerBridge.nextRealSegmentReady(segmentIndex: nextSegmentIndex)
    }

    @MainActor
    private static func stopQwenFiller(reason: String) {
        qwenComputeFillerBridge.playbackStopped(reason: reason)
    }

    static func run(
        preset: TuringNativeQwenVoiceDesignCanaryPreset = .bigMikeShortDynamic
    ) async {
        let input = preset.input
        let requestedRows = preset.maxNewTokens(for: input.spokenText)

        do {
            print("""
            [TuringQwenNativeHello] requested
              implementation: in_repo_turing_qwen_native
              source: QwenLM/Qwen3-TTS architecture port
              preset: \(preset.rawValue)
              voiceID: \(input.voiceID)
              textUTF16: \(input.spokenText.utf16.count)
              instructUTF16: \(input.instruction.utf16.count)
              estimatedCombinedTokens: \(input.estimatedCombinedTokens)
              maxNewTokens: \(requestedRows)
              generationMode: \(preset.performanceMode == .performance ? "dynamicPerformance" : "dynamicDebug")
              performanceMode: \(preset.performanceMode.rawValue)
              estimatedAudioSeconds: \(String(format: "%.3f", TuringNativeQwenVoiceDesignCanaryPreset.estimatedAudioSeconds(rows: requestedRows)))
              rowBudgetMode: \(preset.usesDynamicRowCeiling ? "textLengthCeiling" : "fixedDiagnostic")
              minimumUsefulRows: \(TuringNativeQwenVoiceDesignCanaryPreset.minimumUsefulSpeechRows)
              usefulForSegmentation: \(preset.isUsefulSpeechLength)
              spokenText:
            \(input.spokenText)
              episodePickerButton: true
              prologueBypassed: true
              turingHostBypassed: true
              turingSchedulerBypassed: true
              turingAudioCacheBypassed: true
              thirdPartyQwenFrameworkBypassed: true
              runtimeNetworkAllowed: false
            """)

            let modelRoot = try locateBundledVoiceDesignModel()
            TuringMemoryBudgetProbe.log(
                label: "beforeQwenStage",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            let stagedRoot = try stageWritableModel(from: modelRoot)
            TuringMemoryBudgetProbe.log(
                label: "afterQwenStage",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            TuringMemoryBudgetProbe.log(
                label: "beforeQwenLoad",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            let engine = try await TuringQwenNativeVoiceDesignEngine(
                modelRoot: stagedRoot,
                trace: .stdout(prefix: "[TuringQwenNative]")
            )
            TuringMemoryBudgetProbe.log(
                label: "afterQwenLoad",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            TuringMemoryBudgetProbe.log(
                label: "beforeQwenGenerate",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            if preset.isLongform {
                try await runLongform(
                    preset: preset,
                    engine: engine
                )
            } else {
                startQwenComputeFiller(
                    segmentIndex: 0,
                    reason: "singleClipComputeStarted"
                )
                let audio = try await renderSingleClip(
                    preset: preset,
                    input: input,
                    engine: engine,
                    segmentIndex: 0
                )
                stopQwenComputeFiller(
                    segmentIndex: 0,
                    reason: "singleClipReadyForPlayback"
                )

                print("""
                [TuringQwenNativeHello] generation finished
                  sampleRate: \(audio.sampleRate)
                  sampleCount: \(audio.samples.count)
                  durationSeconds: \(String(format: "%.3f", audio.durationSeconds))
                  peakAbs: \(audio.peakAbs)
                  rms: \(audio.rms)
                """)

                try await TuringQwenNativeMemoryPlayer.shared.play(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate
                )
            }
            TuringMemoryBudgetProbe.log(
                label: "afterQwenGenerate",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            TuringMemoryBudgetProbe.log(
                label: "afterPlayback",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
            TuringMemoryBudgetProbe.log(label: "afterTransientCleanup")
            TuringMemoryBudgetProbe.log(label: "afterQwenUnload")

            print("[TuringQwenNativeHello] playback finished")
        } catch {
            stopQwenFiller(reason: "qwenNativeRunFailed")
            TuringMemoryBudgetProbe.log(label: "afterTransientCleanup")
            TuringMemoryBudgetProbe.log(label: "afterQwenUnload")

            print("""
            [TuringQwenNativeHello] failed
              error: \(error)
            """)
        }
    }

    private static func renderSingleClip(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        input: TuringNativeQwenVoiceDesignCanaryInput,
        engine: TuringQwenNativeVoiceDesignEngine,
        segmentIndex: Int
    ) async throws -> TuringQwenNativeAudio {
        if preset.isFixtureDecode {
            return try await engine.generateVoiceDesignFixtureDecode(
                text: input.spokenText,
                instruct: input.instruction,
                fixtureRows: TuringQwenNativeVoiceDesignEngine.sourceTruthFixtureRows,
                memoryLabel: "\(preset.rawValue).segment.\(segmentIndex)"
            )
        }

        let maxNewTokens = preset.maxNewTokens(for: input.spokenText)
        return try await engine.generateVoiceDesignDynamic(
            text: input.spokenText,
            instruct: input.instruction,
            maxNewTokens: maxNewTokens,
            memoryLabel: "\(preset.rawValue).segment.\(segmentIndex)",
            performanceMode: preset.performanceMode
        )
    }

    private static func runLongform(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        engine: TuringQwenNativeVoiceDesignEngine
    ) async throws {
        let baseInput = preset.input
        print("""
        [TuringQwenNativeHello] longform dynamic started
          preset: \(preset.rawValue)
          segmentCount: \(preset.segments.count)
          rowBudgetMode: textLengthCeiling
          maximumDynamicRows: \(TuringNativeQwenVoiceDesignCanaryPreset.maximumDynamicSpeechRows)
          fixtureRowsUsed: false
        """)

        guard let firstSegment = preset.segments.first else {
            return
        }

        var nextSegmentIndex = 0
        startQwenComputeFiller(
            segmentIndex: nextSegmentIndex,
            reason: "longformInitialSegmentComputeStarted"
        )
        var readyAudio = try await renderLongformSegment(
            preset: preset,
            baseInput: baseInput,
            segment: firstSegment,
            segmentIndex: nextSegmentIndex,
            engine: engine
        )
        stopQwenComputeFiller(
            segmentIndex: nextSegmentIndex,
            reason: "longformInitialSegmentReadyForPlayback"
        )
        nextSegmentIndex += 1

        var playbackIndex = 0
        while playbackIndex < preset.segments.count {
            let audioForPlayback = readyAudio
            let currentSegmentIndex = playbackIndex
            let renderAheadSegmentIndex = nextSegmentIndex

            let renderReadiness: LongformRenderReadiness?
            let renderAheadTask: Task<TuringQwenNativeAudio, Error>?
            if renderAheadSegmentIndex < preset.segments.count {
                let readiness = LongformRenderReadiness()
                renderReadiness = readiness
                renderAheadTask = Task {
                    do {
                        let audio = try await renderLongformSegment(
                            preset: preset,
                            baseInput: baseInput,
                            segment: preset.segments[renderAheadSegmentIndex],
                            segmentIndex: renderAheadSegmentIndex,
                            engine: engine
                        )
                        await readiness.markReady()
                        return audio
                    } catch {
                        await readiness.markReady()
                        throw error
                    }
                }
            } else {
                renderReadiness = nil
                renderAheadTask = nil
            }

            print("""
            [TuringQwenNativeLongform] real segment playback started
              segmentIndex: \(currentSegmentIndex)
              sampleCount: \(audioForPlayback.samples.count)
              sampleRate: \(audioForPlayback.sampleRate)
              durationSeconds: \(String(format: "%.3f", audioForPlayback.durationSeconds))
              computeAhead: \(renderAheadTask != nil)
            """)

            let playbackTask = Task {
                try await TuringQwenNativeMemoryPlayer.shared.play(
                    samples: audioForPlayback.samples,
                    sampleRate: audioForPlayback.sampleRate
                )
            }

            do {
                try await playbackTask.value
            } catch {
                renderAheadTask?.cancel()
                stopQwenFiller(reason: "playbackFailed.segment\(currentSegmentIndex)")
                throw error
            }

            var fillerStarted = false
            if let renderReadiness, await renderReadiness.isReady() == false {
                fillerStarted = true
                startLongformGapFiller(
                    previousSegmentIndex: currentSegmentIndex,
                    nextSegmentIndex: renderAheadSegmentIndex
                )
            }

            TuringMemoryBudgetProbe.log(
                label: "afterLongformSegment.\(currentSegmentIndex)",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )

            guard let renderAheadTask else {
                break
            }

            do {
                readyAudio = try await renderAheadTask.value
                if fillerStarted {
                    stopLongformGapFillerForReadySegment(nextSegmentIndex: renderAheadSegmentIndex)
                }
            } catch {
                if fillerStarted {
                    stopQwenFiller(reason: "renderFailed.segment\(renderAheadSegmentIndex)")
                }
                throw error
            }

            playbackIndex += 1
            nextSegmentIndex += 1
        }

        stopQwenFiller(reason: "longformComplete")

        print("""
        [TuringQwenNativeHello] longform dynamic finished
          preset: \(preset.rawValue)
          segmentCount: \(preset.segments.count)
          fixtureRowsUsed: false
        """)
    }

    private static func renderLongformSegment(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        baseInput: TuringNativeQwenVoiceDesignCanaryInput,
        segment: String,
        segmentIndex: Int,
        engine: TuringQwenNativeVoiceDesignEngine
    ) async throws -> TuringQwenNativeAudio {
        let input = TuringNativeQwenVoiceDesignCanaryInput(
            voiceID: baseInput.voiceID,
            language: baseInput.language,
            spokenText: segment,
            instruction: baseInput.instruction
        )

        print("""
        [TuringQwenNativeHello] longform segment render started
          segmentIndex: \(segmentIndex)
          textUTF16: \(segment.utf16.count)
          maxNewTokens: \(preset.maxNewTokens(for: segment))
          rowBudgetMode: textLengthCeiling
          fixtureRowsUsed: false
        """)

        return try await renderSingleClip(
            preset: preset,
            input: input,
            engine: engine,
            segmentIndex: segmentIndex
        )
    }

    private static func locateBundledVoiceDesignModel() throws -> URL {
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
            domain: "TuringNativeQwenHelloWorldCanary",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: """
                Bundled Qwen VoiceDesign bf16 model not found. Expected \(expectedModelFolderName). Available Qwen model folders: \(availableSummary).
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
            .appendingPathComponent("TuringQwenNativeHelloWorld", isDirectory: true)
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
            [TuringQwenNativeHello] writable stage ready
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
        [TuringQwenNativeHello] writable stage ready
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
