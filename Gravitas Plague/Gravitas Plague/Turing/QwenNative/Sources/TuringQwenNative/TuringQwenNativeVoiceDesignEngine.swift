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
        let tokenizer = try Self.withStage(
            .tokenizerLoad,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try Self.preflightTokenizer(modelRoot: modelRoot)
            return try TuringQwenNativeTokenizer(modelRoot: modelRoot)
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
                englishLanguageID: config.talkerConfig.codecLanguageID["english"],
                tokenizer: tokenizer
            )
        }

        trace.tensor(
            "prompt.assistantInputIDs",
            shape: [1, prompt.assistantInputIDs.count],
            dtype: "int64",
            ndim: 2
        )
        trace.tensor(
            "prompt.instructInputIDs",
            shape: [1, prompt.instructInputIDs.count],
            dtype: "int64",
            ndim: 2
        )

        try Self.withStage(
            .promptEmbeddingsEval,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            let assistantIDs = MLXArray(
                int64: prompt.assistantInputIDs,
                [1, prompt.assistantInputIDs.count]
            )
            let instructIDs = MLXArray(
                int64: prompt.instructInputIDs,
                [1, prompt.instructInputIDs.count]
            )
            eval(assistantIDs, instructIDs)
        }

        let talkerPromptInputs = try Self.withStage(
            .talkerPromptInputEval,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeTalkerPromptInputBuilder.build(
                prompt: prompt,
                config: config,
                tensorIndex: tensorIndex
            )
        }

        trace.tensor(
            "talker.inputsEmbeds",
            shape: [1, talkerPromptInputs.sequenceLength, talkerPromptInputs.hiddenSize],
            dtype: "float32",
            ndim: 3
        )
        trace.tensor(
            "talker.attentionMask",
            shape: [1, talkerPromptInputs.sequenceLength],
            dtype: "int64",
            ndim: 2
        )
        trace.tensor(
            "talker.trailingTextHidden",
            shape: [1, 1, talkerPromptInputs.hiddenSize],
            dtype: "float32",
            ndim: 3
        )
        trace.tensor(
            "talker.ttsPadEmbed",
            shape: [1, 1, talkerPromptInputs.hiddenSize],
            dtype: "float32",
            ndim: 3
        )

        let layer0Output = try Self.withStage(
            .talkerLayer0Eval,
            trace: trace,
            breadcrumbs: breadcrumbs
        ) {
            try TuringQwenNativeTalkerLayer0Runner.run(
                promptInputs: talkerPromptInputs,
                config: config,
                tensorIndex: tensorIndex
            )
        }

        trace.tensor(
            "talker.layer0.hiddenStates",
            shape: [1, layer0Output.sequenceLength, layer0Output.hiddenSize],
            dtype: "float32",
            ndim: 3
        )

        throw TuringQwenNativeError.nativeGenerationNotImplemented(
            "TuringQwenNative preflight, tokenizer, safetensors row loading, official VoiceDesign prompt embedding projection, codec prefill, first talker input tensor eval, and talker decoder layer 0 eval completed. The remaining talker layers, codec sampling, code predictor, and speech decoder still need to be ported before audio can be generated."
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
    let assistantText: String
    let instructText: String
    let assistantInputIDs: [Int]
    let instructInputIDs: [Int]
}

enum TuringQwenNativeVoiceDesignPromptBuilder {
    static func build(
        text: String,
        voiceDescription: String,
        language: String,
        englishLanguageID: Int?,
        tokenizer: TuringQwenNativeTokenizer
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

        let assistantText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let instructText = "<|im_start|>user\n\(voiceDescription)<|im_end|>\n"

        return TuringQwenNativeVoiceDesignPrompt(
            assistantText: assistantText,
            instructText: instructText,
            assistantInputIDs: try tokenizer.encode(assistantText),
            instructInputIDs: try tokenizer.encode(instructText)
        )
    }
}
