#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
import Foundation
import Metal
@preconcurrency import MLX
@preconcurrency import MLXLMCommon
import MLXAudioCore
import MLXAudioTTS

private struct TuringUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

actor QwenMLXAudioModelHost: QwenTTSModelHost {
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String

    private let descriptor: TuringModelDescriptor
    private let runtime: TuringRuntimeConfig
    private let bundle: Bundle
    private var loadedModel: (any SpeechGenerationModel)?

    init(
        descriptor: TuringModelDescriptor,
        runtime: TuringRuntimeConfig,
        bundle: Bundle = .main
    ) {
        self.descriptor = descriptor
        self.runtime = runtime
        self.bundle = bundle
        modelID = descriptor.id
        modelRevision = descriptor.modelRevision
        quantization = descriptor.quantization
        tokenizerRevision = descriptor.tokenizerRevision
    }

    func assertGPUAvailable() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw TuringRuntimeError.qwenGPUUnavailable
        }

        do {
            try Device.withDefaultDevice(.gpu) {
                let probe = MLXArray(Float(1))
                eval(probe)
            }
        } catch {
            throw TuringRuntimeError.qwenGPUUnavailable
        }
    }

    func loadIfNeeded() async throws {
        try QwenPhase0CompatibilityGate.validate(
            model: descriptor,
            runtime: runtime.tts
        )
        try await assertGPUAvailable()
        if loadedModel != nil {
            return
        }

        let modelRoot = try TuringResourceLoader.resourceURL(
            resourcePath: descriptor.resourcePath,
            bundle: bundle
        )
        let safetensorsURL = modelRoot.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: safetensorsURL.path) else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Missing model.safetensors at \(safetensorsURL.path)."
            )
        }
        let modelDescriptor = descriptor

        do {
            let modelBox = try await Task.detached(
                priority: .userInitiated
            ) { () async throws -> TuringUncheckedSendableBox<any SpeechGenerationModel> in
                return try await Device.withDefaultDevice(.gpu) { () async throws -> TuringUncheckedSendableBox<any SpeechGenerationModel> in
                    let loadableModelRoot = try Self.writableModelRootIfNeeded(
                        bundledModelRoot: modelRoot,
                        descriptor: modelDescriptor
                    )

                    print(
                        """
                        [TuringTTS] loading Qwen Phase 0 model
                          modelID: \(modelDescriptor.id)
                          quantization: \(modelDescriptor.quantization)
                          path: \(loadableModelRoot.path)
                        """
                    )

                    let model = try await TTS.loadModel(
                        modelRepo: loadableModelRoot.path,
                        modelType: modelDescriptor.modelType
                    )
                    return TuringUncheckedSendableBox(value: model)
                }
            }.value
            loadedModel = modelBox.value
        } catch {
            throw TuringRuntimeError.qwenModelLoadFailed(
                error.localizedDescription
            )
        }
    }

    nonisolated private static func writableModelRootIfNeeded(
        bundledModelRoot: URL,
        descriptor: TuringModelDescriptor
    ) throws -> URL {
        let tokenizerJSON = bundledModelRoot.appendingPathComponent("tokenizer.json")
        if FileManager.default.fileExists(atPath: tokenizerJSON.path) {
            return bundledModelRoot
        }

        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "TuringWritableModels",
            isDirectory: true
        )

        let safeRevision = descriptor.modelRevision
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        let stagedRoot = cacheRoot.appendingPathComponent(
            "\(descriptor.id)-\(safeRevision)",
            isDirectory: true
        )

        let stagedWeights = stagedRoot.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: stagedWeights.path) {
            return stagedRoot
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: stagedRoot.path) {
            try fileManager.removeItem(at: stagedRoot)
        }

        try fileManager.copyItem(
            at: bundledModelRoot,
            to: stagedRoot
        )

        print(
            """
            [TuringTTS] staged writable Qwen model
              source: \(bundledModelRoot.path)
              destination: \(stagedRoot.path)
              reason: tokenizer_json_generation_requires_writable_directory
            """
        )

        return stagedRoot
    }

    func makeSession() async throws -> QwenTTSSynthesisSession {
        try await loadIfNeeded()
        guard let loadedModel else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Loaded model handle is missing after loadIfNeeded()."
            )
        }

        return QwenMLXAudioSynthesisSession(
            model: loadedModel
        )
    }
}

struct QwenMLXAudioSynthesisSession: QwenTTSSynthesisSession, @unchecked Sendable {
    private let modelBox: TuringUncheckedSendableBox<any SpeechGenerationModel>

    init(
        model: any SpeechGenerationModel
    ) {
        modelBox = TuringUncheckedSendableBox(value: model)
    }

    func synthesize(
        text: String,
        emotion: String,
        voice: TuringVoiceDescriptor,
        settings: QwenGenerationSettings
    ) async throws -> QwenWaveform {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Cannot synthesize empty text."
            )
        }

        let modelBox = modelBox

        return try await Task.detached(
            priority: .userInitiated
        ) { () async throws -> QwenWaveform in
            try QwenPhase0CompatibilityGate.validateGenerateRequest(
                text: trimmed,
                voiceArgument: nil,
                refAudioWasProvided: false,
                refText: nil,
                settings: settings
            )

            return try await Device.withDefaultDevice(.gpu) { () async throws -> QwenWaveform in
                let model = modelBox.value
                var generationParameters = model.defaultGenerationParameters
                generationParameters.maxTokens = settings.maxTokens
                generationParameters.temperature = Float(settings.temperature)
                generationParameters.topP = Float(settings.topP)
                generationParameters.repetitionPenalty = Float(settings.repetitionPenalty)
                _ = voice
                _ = emotion

                print(
                    """
                    [TuringTTS] Qwen Phase 0 generation starting
                      textCharacters: \(trimmed.count)
                      language: \(settings.language)
                      maxTokens: \(settings.maxTokens)
                      voiceArgument: nil
                      refAudio: nil
                      refText: nil
                    """
                )

                let audio = try await model.generate(
                    text: trimmed,
                    voice: nil,
                    refAudio: nil,
                    refText: nil,
                    language: settings.language,
                    generationParameters: generationParameters
                )

                let samples = audio.asArray(Float.self)
                guard samples.isEmpty == false else {
                    throw TuringRuntimeError.qwenSynthesisFailed(
                        "Qwen returned an empty waveform."
                    )
                }

                print(
                    """
                    [TuringTTS] Qwen Phase 0 generation finished
                      sampleCount: \(samples.count)
                      sampleRate: \(model.sampleRate)
                    """
                )

                return QwenWaveform(
                    samples: samples,
                    sampleRate: model.sampleRate,
                    channelCount: 1
                )
            }
        }.value
    }

    func releaseTransientState() async {
        Memory.clearCache()
    }
}
#else
import Foundation

actor QwenMLXAudioModelHost: QwenTTSModelHost {
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String

    init(
        descriptor: TuringModelDescriptor,
        runtime: TuringRuntimeConfig,
        bundle: Bundle = .main
    ) {
        _ = runtime
        _ = bundle
        modelID = descriptor.id
        modelRevision = descriptor.modelRevision
        quantization = descriptor.quantization
        tokenizerRevision = descriptor.tokenizerRevision
    }

    func assertGPUAvailable() async throws {
        throw TuringRuntimeError.qwenGPUUnavailable
    }

    func loadIfNeeded() async throws {
        throw TuringRuntimeError.qwenModelLoadFailed(
            "MLXAudioTTS/MLXAudioCore/MLX are not available in this build."
        )
    }

    func makeSession() async throws -> QwenTTSSynthesisSession {
        throw TuringRuntimeError.qwenModelLoadFailed(
            "MLXAudioTTS/MLXAudioCore/MLX are not available in this build."
        )
    }
}
#endif
