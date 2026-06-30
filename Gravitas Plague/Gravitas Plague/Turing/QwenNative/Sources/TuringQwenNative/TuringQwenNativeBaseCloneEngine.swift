import Foundation

public actor TuringQwenNativeBaseCloneEngine {
    private let modelRoot: URL
    private let trace: TuringQwenNativeTrace
    private let weightBackend: TuringQwenNativeWeightBackend
    private let config: TuringQwenNativeConfig

    public init(
        modelRoot: URL,
        weightBackend: TuringQwenNativeWeightBackend = .baseCloneRuntime,
        trace: TuringQwenNativeTrace = .stdout(prefix: "[TuringQwenNativeBaseClone]")
    ) throws {
        self.modelRoot = modelRoot
        self.trace = trace
        self.weightBackend = weightBackend

        try Self.preflightModelRoot(modelRoot)
        let loadedConfig = try TuringQwenNativeConfig.load(from: modelRoot)
        try loadedConfig.validateBaseCloneRuntime()
        self.config = loadedConfig
        try TuringQwenNativeQuantizedLinear(
            tensorPrefix: "model",
            backend: weightBackend.kind,
            groupSize: loadedConfig.quantization?.groupSize ?? 64,
            bits: loadedConfig.quantization?.bits ?? 4
        )
        .preflightOnly()
    }

    public func generateBaseClone(
        prompt: TuringQwenNativeBaseClonePrompt
    ) async throws -> TuringQwenNativeAudio {
        trace.stageStarted(.fullGenerate)
        defer {
            trace.stageCompleted(.fullGenerate)
        }

        print("""
        [TuringQwenNativeBaseClone] generation requested
          voiceID: \(prompt.cloneProfile.voiceID)
          variantID: \(prompt.cloneProfile.defaultVariantID)
          targetCharacters: \(prompt.text.utf16.count)
          rawReferenceRuntime: false
          precomputedCloneArtifacts: true
        """)

        let conditioning = try TuringQwenNativeBaseCloneConditioningBuilder()
            .load(profile: prompt.cloneProfile)
        let tokenizer = try TuringQwenNativeTokenizer(modelRoot: modelRoot)
        let preparedPrompt = try TuringQwenNativeBaseCloneInputBuilder.build(
            request: TuringQwenNativeBaseClonePromptRequest(
                targetText: prompt.text,
                targetLanguage: prompt.language,
                cloneArtifacts: conditioning.artifacts
            ),
            config: config,
            tokenizer: tokenizer
        )

        print("""
        [TuringQwenNativeBaseClone] artifacts loaded
          refTextTokenCount: \(preparedPrompt.refTextTokens.count)
          referenceRows: \(preparedPrompt.referenceRowCount)
          codebookCount: \(conditioning.artifacts.codebookCount)
          speakerEmbeddingShape: [\(preparedPrompt.speakerEmbedding.count)]
          xVectorOnlyMode: \(preparedPrompt.xVectorOnlyMode)
          iclMode: true
        """)

        print("""
        [TuringQwenNativeBaseClone] model loaded
          modelID: \(prompt.cloneProfile.modelID)
          ttsModelType: \(config.ttsModelType)
          quantization: \(config.quantization?.bits ?? 0)bit
          weightBackend: mlxQuantizedMatmul
        """)

        print("""
        [TuringQwenNativeBaseClone] prompt built
          layout: \(preparedPrompt.layout)
          targetTokenCount: \(preparedPrompt.targetInputIDs.count)
          languageCodecID: \(preparedPrompt.languageCodecID)
        """)

        print("""
        [TuringQwenNativeBaseClone] dynamic generation started
          voiceID: \(prompt.cloneProfile.voiceID)
          variantID: \(conditioning.variant.variantID)
          fixtureRowsUsed: false
          xVectorOnlyMode: false
          mode: icl
          residentWeights: true
          runtimePerStepFileIO: false
        """)

        throw TuringQwenNativeError.nativeGenerationNotImplemented(
            "Base clone artifacts are ready, but the Base 4-bit forward pass still needs the shared talker/code-predictor runners switched from dense-only projections to TuringQwenNativeLinearWeight."
        )
    }

    private static func preflightModelRoot(_ root: URL) throws {
        let required = [
            "config.json",
            "model.safetensors",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "speech_tokenizer"
        ]

        for relativePath in required {
            let url = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TuringQwenNativeError.missingModelFile(relativePath)
            }
        }

        let configURL = root.appendingPathComponent("config.json")
        let config = try TuringQwenNativeConfig.load(from: root)
        try config.validateBaseCloneRuntime()
        let data = try Data(contentsOf: configURL)
        let baseConfig = try JSONDecoder().decode(BaseConfig.self, from: data)
        guard baseConfig.modelType == "qwen3_tts" else {
            throw TuringQwenNativeError.invalidConfig(
                "model_type must be qwen3_tts, got \(baseConfig.modelType)"
            )
        }
        guard baseConfig.ttsModelType == "base" else {
            throw TuringQwenNativeError.invalidConfig(
                "tts_model_type must be base for Base clone runtime, got \(baseConfig.ttsModelType)"
            )
        }
    }

    private struct BaseConfig: Decodable {
        let modelType: String
        let ttsModelType: String

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case ttsModelType = "tts_model_type"
        }
    }
}
