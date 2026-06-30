import Foundation
import MLX

public struct TuringQwenNativeAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public var peakAbs: Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    public var rms: Float {
        guard samples.isEmpty == false else { return 0 }
        let sum = samples.reduce(Double(0)) {
            $0 + Double($1 * $1)
        }
        return Float(sqrt(sum / Double(samples.count)))
    }
}

public actor TuringQwenNativeVoiceDesignEngine {
    private let modelRoot: URL
    private let trace: TuringQwenNativeTrace
    private let breadcrumbs: TuringQwenNativeStageBreadcrumbs
    private let config: TuringQwenNativeConfig
    private let tensorIndex: TuringQwenNativeSafetensorsIndex

    public init(
        modelRoot: URL,
        trace: TuringQwenNativeTrace
    ) async throws {
        self.modelRoot = modelRoot
        self.trace = trace
        self.breadcrumbs = try TuringQwenNativeStageBreadcrumbs()

        breadcrumbs.logPreviousRunIfNeeded(prefix: "[TuringQwenNativeHello]")

        self.config = try Self.withStage(
            .assetPreflight,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.preflightAssets(modelRoot: modelRoot)
            return try TuringQwenNativeConfig.load(from: modelRoot)
        }

        self.tensorIndex = try Self.withStage(
            .tensorIndexLoad,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeSafetensorsIndex.load(
                from: modelRoot.appendingPathComponent("model.safetensors")
            )
        }

        try Self.withStage(
            .weightMapValidate,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.validateWeightMap(tensorIndex)
        }
    }

    public func generateVoiceDesign(
        text: String,
        voiceDescription: String,
        language: String,
        maxNewTokens: Int,
        seed: UInt64
    ) async throws -> TuringQwenNativeAudio {
        try Self.withStage(
            .tokenizerLoad,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.preflightTokenizer(modelRoot: modelRoot)
        }

        let prompt = try Self.withStage(
            .promptBuild,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeVoiceDesignPromptBuilder.build(
                text: text,
                voiceDescription: voiceDescription,
                language: language,
                englishLanguageID: config.talkerConfig.codecLanguageID["english"]
            )
        }

        trace.tensor(
            "prompt.inputIDs",
            shape: [prompt.inputIDs.count],
            dtype: "int32",
            ndim: 1
        )

        try Self.withStage(
            .promptEmbeddingsEval,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            let ids = MLXArray(prompt.inputIDs)
            eval(ids)
        }

        throw TuringQwenNativeError.nativeGenerationNotImplemented(
            "TuringQwenNative preflight, config parse, safetensors header parse, tokenizer asset check, prompt build, and first MLX input eval completed. The owned talker/code-predictor/speech-decoder graph still needs to be ported before audio can be generated."
        )
    }

    private static func preflightAssets(modelRoot: URL) throws {
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

        for name in required {
            let url = modelRoot.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TuringQwenNativeError.missingModelFile(name)
            }
        }
    }

    private static func preflightTokenizer(modelRoot: URL) throws {
        let required = [
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt"
        ]

        for name in required {
            guard FileManager.default.fileExists(
                atPath: modelRoot.appendingPathComponent(name).path
            ) else {
                throw TuringQwenNativeError.missingModelFile(name)
            }
        }
    }

    private static func validateWeightMap(
        _ index: TuringQwenNativeSafetensorsIndex
    ) throws {
        guard index.tensors.isEmpty == false else {
            throw TuringQwenNativeError.invalidSafetensors("No tensors found in model.safetensors.")
        }

        try index.requireAny(prefixes: [
            "talker."
        ])
    }

    @discardableResult
    private static func withStage<T>(
        _ stage: TuringQwenNativeStage,
        trace: TuringQwenNativeTrace,
        breadcrumbs: TuringQwenNativeStageBreadcrumbs,
        body: () throws -> T
    ) throws -> T {
        breadcrumbs.started(stage)
        trace.stageStarted(stage)
        do {
            let result = try body()
            breadcrumbs.completed(stage)
            trace.stageCompleted(stage)
            return result
        } catch {
            throw error
        }
    }
}

struct TuringQwenNativeVoiceDesignPrompt: Sendable {
    let inputIDs: [Int32]
}

enum TuringQwenNativeVoiceDesignPromptBuilder {
    static func build(
        text: String,
        voiceDescription: String,
        language: String,
        englishLanguageID: Int?
    ) throws -> TuringQwenNativeVoiceDesignPrompt {
        guard text.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("VoiceDesign text is empty.")
        }
        guard voiceDescription.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("VoiceDesign instruction is empty.")
        }
        guard language.lowercased() == "english",
              englishLanguageID != nil else {
            throw TuringQwenNativeError.invalidConfig("Only english VoiceDesign canary is wired.")
        }

        // TODO: Port QwenLM/Qwen3-TTS generate_voice_design prompt construction exactly.
        // This placeholder is intentionally only a local byte-level transport probe so
        // the native package owns model asset, tokenizer, and MLX eval boundaries first.
        let prompt = "VoiceDesign:\nInstruction:\n\(voiceDescription)\nText:\n\(text)"
        return TuringQwenNativeVoiceDesignPrompt(
            inputIDs: prompt.utf8.map(Int32.init)
        )
    }
}
