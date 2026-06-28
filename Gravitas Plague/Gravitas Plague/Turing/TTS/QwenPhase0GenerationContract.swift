import Foundation

struct QwenPhase0GenerationContract: Sendable {
    enum ContractError: LocalizedError, Equatable {
        case emptyText
        case invalidModelID(String)
        case invalidCheckpointKind(String)
        case invalidQuantization(String)
        case invalidGenerationMode(String)
        case voiceArgumentForbidden(String)
        case refAudioForbidden
        case refTextForbidden(String)
        case gpuRequired
        case cpuFallbackForbidden
        case mainActorForbidden

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "Phase 0 Qwen smoke text is empty."
            case .invalidModelID(let value):
                return "Phase 0 requires a 0.6B Base Qwen3-TTS model, got \(value)."
            case .invalidCheckpointKind(let value):
                return "Phase 0 requires a Base checkpoint, got \(value)."
            case .invalidQuantization(let value):
                return "Phase 0 requires 8bit or bf16 quantization, got \(value)."
            case .invalidGenerationMode(let value):
                return "Phase 0 requires bareBaseSmoke generation, got \(value)."
            case .voiceArgumentForbidden(let value):
                return "Phase 0 bare Base smoke must pass voice nil, got \(value)."
            case .refAudioForbidden:
                return "Phase 0 bare Base smoke must not pass reference audio."
            case .refTextForbidden(let value):
                return "Phase 0 bare Base smoke must not pass refText, got \(value)."
            case .gpuRequired:
                return "Phase 0 Qwen requires GPU-backed MLX execution."
            case .cpuFallbackForbidden:
                return "Phase 0 Qwen must not allow CPU fallback."
            case .mainActorForbidden:
                return "Phase 0 Qwen generation must not run on MainActor."
            }
        }
    }

    static let allowedModelIDs: Set<String> = [
        "qwen3-tts-12hz-0.6b-base-8bit",
        "qwen3-tts-12hz-0.6b-base-bf16"
    ]
    static let requiredCheckpointKind = "base"
    static let allowedQuantizations: Set<String> = [
        "8bit",
        "bf16"
    ]
    static let requiredGenerationMode = "bareBaseSmoke"

    static func validateBeforeGenerate(
        request: QwenPhase0SmokeRequest,
        modelID: String,
        checkpointKind: String,
        quantization: String,
        generationMode: String,
        voiceArgument: String?,
        hasRefAudio: Bool,
        refText: String?,
        requireGPU: Bool,
        allowCPUFallback: Bool,
        isMainActor: Bool
    ) throws {
        guard request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ContractError.emptyText
        }

        guard allowedModelIDs.contains(modelID) else {
            throw ContractError.invalidModelID(modelID)
        }

        guard checkpointKind == requiredCheckpointKind else {
            throw ContractError.invalidCheckpointKind(checkpointKind)
        }

        guard allowedQuantizations.contains(quantization) else {
            throw ContractError.invalidQuantization(quantization)
        }

        guard generationMode == requiredGenerationMode else {
            throw ContractError.invalidGenerationMode(generationMode)
        }

        if let voice = voiceArgument?.trimmingCharacters(in: .whitespacesAndNewlines),
           !voice.isEmpty {
            throw ContractError.voiceArgumentForbidden(voice)
        }

        guard hasRefAudio == false else {
            throw ContractError.refAudioForbidden
        }

        if let refText = refText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refText.isEmpty {
            throw ContractError.refTextForbidden(refText)
        }

        guard requireGPU else {
            throw ContractError.gpuRequired
        }

        guard allowCPUFallback == false else {
            throw ContractError.cpuFallbackForbidden
        }

        guard isMainActor == false else {
            throw ContractError.mainActorForbidden
        }
    }
}
