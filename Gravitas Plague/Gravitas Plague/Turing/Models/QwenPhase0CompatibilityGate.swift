import Foundation

enum QwenPhase0CompatibilityGate {
    static let allowedModelIDs: Set<String> = [
        "qwen3-tts-12hz-0.6b-base-8bit",
        "qwen3-tts-12hz-0.6b-base-bf16"
    ]
    static let allowedQuantizations: Set<String> = [
        "8bit",
        "bf16"
    ]

    static func validate(
        model: TuringModelDescriptor,
        runtime: TuringRuntimeConfig.TTSConfig
    ) throws {
        guard runtime.phase0AudioOnly else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 runtime must be audio-only. Cloning and authoring are later phases."
            )
        }

        guard allowedModelIDs.contains(model.id) else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 may run only 0.6B Base Qwen3-TTS models, got \(model.id)."
            )
        }

        guard model.phase0RuntimeAllowed else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Model is not allowed in Phase 0 runtime: \(model.id)."
            )
        }

        guard allowedQuantizations.contains(model.quantization) else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 requires 0.6B Base 8-bit or bf16. Got quantization: \(model.quantization)."
            )
        }

        guard model.modelType == "qwen3_tts" else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 requires qwen3_tts modelType. Got \(model.modelType)."
            )
        }

        guard runtime.requireGPU,
              runtime.allowCPUFallback == false,
              model.requiresGPU,
              model.allowCPUFallback == false else {
            throw TuringRuntimeError.qwenGPUUnavailable
        }

        guard runtime.generationMode == QwenPhase0GenerationContract.requiredGenerationMode else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 requires bareBaseSmoke generation mode."
            )
        }

        guard runtime.voiceArgumentPolicy == .baseNilOnly,
              model.voiceArgumentPolicy == "baseNilOnly" else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 bare Base smoke must pass voice nil."
            )
        }

        guard runtime.refAudioPolicy == .phase0NilOnly,
              runtime.refTextPolicy == .phase0NilOnly,
              model.refAudioPolicy == "phase0NilOnly",
              model.refTextPolicy == "phase0NilOnly" else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 must not use reference audio or reference text."
            )
        }

        guard model.customVoiceAllowed == false,
              model.voiceDesignAllowed == false,
              model.cloneProfilesAllowed == false else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 forbids CustomVoice, VoiceDesign, and clone profiles."
            )
        }
    }

    static func validateGenerateRequest(
        text: String,
        voiceArgument: String?,
        refAudioWasProvided: Bool,
        refText: String?,
        settings: QwenGenerationSettings
    ) throws {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 smoke text is empty."
            )
        }

        if let voiceArgument = voiceArgument?.trimmingCharacters(in: .whitespacesAndNewlines),
           voiceArgument.isEmpty == false {
            throw TuringRuntimeError.qwenSynthesisFailed(
                QwenPhase0GenerationContract.ContractError
                    .voiceArgumentForbidden(voiceArgument)
                    .localizedDescription
            )
        }

        guard refAudioWasProvided == false,
              refText == nil else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 must call Qwen with refAudio=nil and refText=nil. Cloning is later."
            )
        }

        guard settings.language == "English" else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 smoke only supports English until the basic canary passes."
            )
        }

        guard (1...512).contains(settings.maxTokens) else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 maxTokens must be 1...512. Got \(settings.maxTokens)."
            )
        }

        guard settings.topP == 1.0,
              settings.repetitionPenalty == 1.0 else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 smoke uses the simplest Qwen sampler path: topP=1.0 and repetitionPenalty=1.0."
            )
        }
    }
}
