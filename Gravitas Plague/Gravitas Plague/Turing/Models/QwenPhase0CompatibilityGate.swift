import Foundation

enum QwenPhase0CompatibilityGate {
    static let allowedModelID = "qwen3-tts-12hz-0.6b-base-8bit"

    static func validate(
        model: TuringModelDescriptor,
        runtime: TuringRuntimeConfig.TTSConfig
    ) throws {
        guard runtime.phase0AudioOnly else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 runtime must be audio-only. Cloning and authoring are later phases."
            )
        }

        guard model.id == allowedModelID else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 may run only \(allowedModelID), got \(model.id)."
            )
        }

        guard model.phase0RuntimeAllowed else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Model is not allowed in Phase 0 runtime: \(model.id)."
            )
        }

        guard model.quantization == "8bit" else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 requires 0.6B Base 8-bit. Got quantization: \(model.quantization)."
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

        guard runtime.voiceArgumentPolicy == .baseNilOnly,
              model.voiceArgumentPolicy == "baseNilOnly" else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Phase 0 Base model must use voice=nil."
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

        guard voiceArgument == nil else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 Base generation must call Qwen with voice=nil."
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
    }
}
