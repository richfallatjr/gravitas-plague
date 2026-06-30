#if DEBUG || GR_TURING_DIAGNOSTICS
import Foundation
import AVFoundation
import TuringQwenNative

enum TuringNativeQwenHelloWorldCanary {
    private static let expectedModelFolderName = "Qwen3-TTS-12Hz-1.7B-Base-4bit"
    private static let activeModelID = "qwen3-tts-12hz-1.7b-base-4bit"
    private static let activeQuantization = "4bit"
    private static let activeRuntimeMode = "baseClone"
    private static let activeWeightBackend = "mlx4bit"

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
    private static func stopQwenFiller(reason: String) {
        qwenComputeFillerBridge.playbackStopped(reason: reason)
    }

    static func run(
        preset: TuringNativeQwenVoiceDesignCanaryPreset = .bigMikeShortDynamic
    ) async {
        let input = preset.input

        do {
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
            let engine = try TuringQwenNativeBaseCloneEngine(
                modelRoot: stagedRoot,
                trace: .stdout(prefix: "[TuringQwenNativeBaseClone]")
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
                    cloneProfile: cloneProfile,
                    engine: engine
                )
            } else {
                let audio = try await renderBaseCloneSegment(
                    preset: preset,
                    cloneProfile: cloneProfile,
                    engine: engine,
                    segment: input.spokenText,
                    segmentIndex: 0
                )

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
            TuringMemoryBudgetProbe.log(label: "afterTransientCleanup")
            TuringMemoryBudgetProbe.log(label: "afterQwenUnload")

            print("[TuringQwenNativeBaseClone] playback finished")
        } catch {
            stopQwenFiller(reason: "qwenBaseCloneRunFailed")
            TuringMemoryBudgetProbe.log(label: "afterTransientCleanup")
            TuringMemoryBudgetProbe.log(label: "afterQwenUnload")

            print("""
            [TuringQwenNativeBaseClone] failed
              error: \(error.localizedDescription)
            """)
        }
    }

    private static func runLongform(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        engine: TuringQwenNativeBaseCloneEngine
    ) async throws {
        print("""
        [TuringQwenNativeBaseClone] longform started
          segmentCount: \(preset.segments.count)
          modelID: \(activeModelID)
          runtimeMode: \(activeRuntimeMode)
          quantization: \(activeQuantization)
          weightBackend: \(activeWeightBackend)
        """)

        for (index, segment) in preset.segments.enumerated() {
            let audio = try await renderBaseCloneSegment(
                preset: preset,
                cloneProfile: cloneProfile,
                engine: engine,
                segment: segment,
                segmentIndex: index
            )

            try await TuringQwenNativeMemoryPlayer.shared.play(
                samples: audio.samples,
                sampleRate: audio.sampleRate
            )
        }
    }

    private static func renderBaseCloneSegment(
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        cloneProfile: TuringQwenNativeCloneProfile,
        engine: TuringQwenNativeBaseCloneEngine,
        segment: String,
        segmentIndex: Int
    ) async throws -> TuringQwenNativeAudio {
        startQwenComputeFiller(
            segmentIndex: segmentIndex,
            reason: "baseCloneSegmentComputeStarted"
        )
        defer {
            stopQwenComputeFiller(
                segmentIndex: segmentIndex,
                reason: "baseCloneSegmentReadyOrFailed"
            )
        }

        let prompt = TuringQwenNativeBaseClonePrompt(
            text: segment,
            language: preset.input.language,
            cloneProfile: cloneProfile
        )

        print("""
        [TuringQwenNativeBaseClone] segment render started
          segmentIndex: \(segmentIndex)
          textUTF16: \(segment.utf16.count)
          cloneProfileLoaded: true
          profileKind: \(cloneProfile.profileKind)
          cloneArtifactsRequired: true
          refTextCharacters: \(cloneProfile.referenceText.utf16.count)
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
