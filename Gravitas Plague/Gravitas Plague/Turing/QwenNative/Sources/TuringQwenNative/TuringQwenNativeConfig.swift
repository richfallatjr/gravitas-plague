import Foundation

public struct TuringQwenNativeConfig: Decodable, Sendable {
    public let modelType: String
    public let ttsModelType: String
    public let ttsModelSize: String?
    public let tokenizerType: String?
    public let ttsBosTokenID: Int
    public let ttsEosTokenID: Int
    public let ttsPadTokenID: Int
    public let talkerConfig: TalkerConfig

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case ttsModelType = "tts_model_type"
        case ttsModelSize = "tts_model_size"
        case tokenizerType = "tokenizer_type"
        case ttsBosTokenID = "tts_bos_token_id"
        case ttsEosTokenID = "tts_eos_token_id"
        case ttsPadTokenID = "tts_pad_token_id"
        case talkerConfig = "talker_config"
    }

    public struct TalkerConfig: Decodable, Sendable {
        public let hiddenSize: Int
        public let textHiddenSize: Int
        public let textVocabSize: Int
        public let vocabSize: Int
        public let numCodeGroups: Int
        public let numHiddenLayers: Int
        public let numAttentionHeads: Int
        public let numKeyValueHeads: Int
        public let headDim: Int
        public let intermediateSize: Int
        public let rmsNormEps: Double
        public let ropeTheta: Double
        public let codecLanguageID: [String: Int]
        public let codecThinkID: Int
        public let codecThinkBosID: Int
        public let codecThinkEosID: Int
        public let codecPadID: Int
        public let codecBosID: Int
        public let codecEosTokenID: Int
        public let codePredictorConfig: CodePredictorConfig

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case textHiddenSize = "text_hidden_size"
            case textVocabSize = "text_vocab_size"
            case vocabSize = "vocab_size"
            case numCodeGroups = "num_code_groups"
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case intermediateSize = "intermediate_size"
            case rmsNormEps = "rms_norm_eps"
            case ropeTheta = "rope_theta"
            case codecLanguageID = "codec_language_id"
            case codecThinkID = "codec_think_id"
            case codecThinkBosID = "codec_think_bos_id"
            case codecThinkEosID = "codec_think_eos_id"
            case codecPadID = "codec_pad_id"
            case codecBosID = "codec_bos_id"
            case codecEosTokenID = "codec_eos_token_id"
            case codePredictorConfig = "code_predictor_config"
        }
    }

    public struct CodePredictorConfig: Decodable, Sendable {
        public let hiddenSize: Int?
        public let vocabSize: Int?
        public let numHiddenLayers: Int?
        public let numAttentionHeads: Int?
        public let numKeyValueHeads: Int?
        public let headDim: Int?
        public let intermediateSize: Int?
        public let rmsNormEps: Double?
        public let ropeTheta: Double?
        public let numCodeGroups: Int?

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case vocabSize = "vocab_size"
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case intermediateSize = "intermediate_size"
            case rmsNormEps = "rms_norm_eps"
            case ropeTheta = "rope_theta"
            case numCodeGroups = "num_code_groups"
        }
    }

    static func load(from modelRoot: URL) throws -> TuringQwenNativeConfig {
        let url = modelRoot.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(TuringQwenNativeConfig.self, from: data)

        guard config.modelType == "qwen3_tts" else {
            throw TuringQwenNativeError.invalidConfig("model_type must be qwen3_tts, got \(config.modelType)")
        }
        guard config.ttsModelType == "voice_design" else {
            throw TuringQwenNativeError.invalidConfig("tts_model_type must be voice_design, got \(config.ttsModelType)")
        }
        guard config.tokenizerType == nil || config.tokenizerType == "qwen3_tts_tokenizer_12hz" else {
            throw TuringQwenNativeError.invalidConfig("Unexpected tokenizer_type: \(config.tokenizerType ?? "nil")")
        }
        guard config.talkerConfig.codecLanguageID["english"] != nil else {
            throw TuringQwenNativeError.invalidConfig("Missing talker_config.codec_language_id.english")
        }

        return config
    }
}

public enum TuringQwenNativeError: Error, CustomStringConvertible, Sendable {
    case missingModelFile(String)
    case invalidConfig(String)
    case invalidSafetensors(String)
    case tokenizer(String)
    case nativeGenerationNotImplemented(String)
    case emptyAudio

    public var description: String {
        switch self {
        case .missingModelFile(let file):
            return "Missing Qwen model file: \(file)"
        case .invalidConfig(let message):
            return "Invalid Qwen config: \(message)"
        case .invalidSafetensors(let message):
            return "Invalid safetensors file: \(message)"
        case .tokenizer(let message):
            return "Qwen tokenizer error: \(message)"
        case .nativeGenerationNotImplemented(let message):
            return message
        case .emptyAudio:
            return "Native Qwen generation produced no audio samples"
        }
    }
}
