#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation
import AVFoundation
import TuringQwenNative

enum TuringNativeQwenHelloWorldCanary {
    private static let expectedModelFolderName = "Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
    private static let activeModelID = "qwen3-tts-12hz-1.7b-voicedesign-bf16"
    private static let activeQuantization = "bf16"

    static func run(
        preset: TuringNativeQwenVoiceDesignCanaryPreset = .bigMikeShortDynamic
    ) async {
        let input = preset.input

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
              maxNewTokens: \(preset.maxNewTokens)
              estimatedAudioSeconds: \(String(format: "%.3f", preset.estimatedAudioSeconds))
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
                let audio = try await renderSingleClip(
                    preset: preset,
                    input: input,
                    engine: engine,
                    segmentIndex: 0
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

        return try await engine.generateVoiceDesignDynamic(
            text: input.spokenText,
            instruct: input.instruction,
            maxNewTokens: preset.maxNewTokens,
            memoryLabel: "\(preset.rawValue).segment.\(segmentIndex)"
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
          fixtureRowsUsed: false
        """)

        for (index, segment) in preset.segments.enumerated() {
            let input = TuringNativeQwenVoiceDesignCanaryInput(
                voiceID: baseInput.voiceID,
                language: baseInput.language,
                spokenText: segment,
                instruction: baseInput.instruction
            )

            print("""
            [TuringQwenNativeHello] longform segment render started
              segmentIndex: \(index)
              textUTF16: \(segment.utf16.count)
              fixtureRowsUsed: false
            """)

            let audio = try await renderSingleClip(
                preset: preset,
                input: input,
                engine: engine,
                segmentIndex: index
            )

            print("""
            [TuringQwenNativeHello] longform segment playback started
              segmentIndex: \(index)
              sampleCount: \(audio.samples.count)
              sampleRate: \(audio.sampleRate)
              durationSeconds: \(String(format: "%.3f", audio.durationSeconds))
            """)

            try await TuringQwenNativeMemoryPlayer.shared.play(
                samples: audio.samples,
                sampleRate: audio.sampleRate
            )

            TuringMemoryBudgetProbe.log(
                label: "afterLongformSegment.\(index)",
                activeQwenModelID: activeModelID,
                quantization: activeQuantization
            )
        }

        print("""
        [TuringQwenNativeHello] longform dynamic finished
          preset: \(preset.rawValue)
          segmentCount: \(preset.segments.count)
          fixtureRowsUsed: false
        """)
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
