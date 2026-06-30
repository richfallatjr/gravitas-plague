#if DEBUG
import Foundation
import AVFoundation
import TuringQwenNative

enum TuringNativeQwenHelloWorldCanary {
    static let text = "Hello world"
    private static let expectedModelFolderName = "Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"

    static let bigMikeDescription = """
    A mid-forties Black American man with a large, grounded physical presence, like a retired college football lineman. Deep chest resonance, heavy but controlled breath, warm gravel, a Baltimore edge, streetwise but intelligent. Tough, protective, tired, and emotionally grounded. Former military, former athlete, current security guard. Not polished, not theatrical, not a radio announcer. He speaks like a real neighbor trying to keep his best friend alive. Thick, weighted vocal texture from age, size, and hard living; low, steady, and human.
    """

    static func run() async {
        do {
            print("""
            [TuringQwenNativeHello] requested
              implementation: in_repo_turing_qwen_native
              source: QwenLM/Qwen3-TTS architecture port
              text: \(text)
              instructCharacters: \(bigMikeDescription.count)
              episodePickerButton: true
              prologueBypassed: true
              turingHostBypassed: true
              turingSchedulerBypassed: true
              turingAudioCacheBypassed: true
              thirdPartyQwenFrameworkBypassed: true
              runtimeNetworkAllowed: false
            """)

            let modelRoot = try locateBundledVoiceDesignModel()
            let stagedRoot = try stageWritableModel(from: modelRoot)

            let engine = try await TuringQwenNativeVoiceDesignEngine(
                modelRoot: stagedRoot,
                trace: .stdout(prefix: "[TuringQwenNative]")
            )

            let audio = try await engine.generateVoiceDesign(
                text: text,
                voiceDescription: bigMikeDescription,
                language: "english",
                maxNewTokens: 256,
                seed: 0
            )

            print("""
            [TuringQwenNativeHello] generation finished
              sampleRate: \(audio.sampleRate)
              sampleCount: \(audio.samples.count)
              peakAbs: \(audio.peakAbs)
              rms: \(audio.rms)
            """)

            try await TuringQwenNativeMemoryPlayer.shared.play(
                samples: audio.samples,
                sampleRate: audio.sampleRate
            )

            print("[TuringQwenNativeHello] playback finished")
        } catch {
            print("""
            [TuringQwenNativeHello] failed
              error: \(error)
            """)
        }
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

        let root = appSupport
            .appendingPathComponent("TuringQwenNativeHelloWorld", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("WritableModel", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)

        try fm.createDirectory(
            at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try fm.copyItem(at: source, to: root)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)

        let probe = root.appendingPathComponent(".write-probe")
        try Data("ok".utf8).write(to: probe)
        try fm.removeItem(at: probe)

        print("""
        [TuringQwenNativeHello] writable stage ready
          source: \(source.path)
          staged: \(root.path)
          writable: true
        """)

        return root
    }
}
#endif
