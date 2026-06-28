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
    let sourceRepository: String

    private let descriptor: TuringModelDescriptor
    private let bundle: Bundle
    private var loadedModel: (any SpeechGenerationModel)?

    init(
        descriptor: TuringModelDescriptor,
        bundle: Bundle = .main
    ) {
        self.descriptor = descriptor
        self.bundle = bundle
        modelID = descriptor.id
        modelRevision = descriptor.modelRevision
        quantization = descriptor.quantization
        tokenizerRevision = descriptor.tokenizerRevision
        sourceRepository = descriptor.sourceRepository
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
            let modelBox = try await Task.detached(priority: .userInitiated) {
                try await Device.withDefaultDevice(.gpu) {
                    let loadableModelRoot = try Self.writableModelRootIfNeeded(
                        bundledModelRoot: modelRoot,
                        descriptor: modelDescriptor
                    )

                    let model = try await TTS.loadModel(
                        modelRepo: loadableModelRoot.path,
                        modelType: "qwen3_tts"
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
            model: loadedModel,
            sourceRepository: sourceRepository
        )
    }
}

struct QwenMLXAudioSynthesisSession: QwenTTSSynthesisSession, @unchecked Sendable {
    private let modelBox: TuringUncheckedSendableBox<any SpeechGenerationModel>
    private let sourceRepository: String

    init(
        model: any SpeechGenerationModel,
        sourceRepository: String
    ) {
        modelBox = TuringUncheckedSendableBox(value: model)
        self.sourceRepository = sourceRepository
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
        let sourceRepository = sourceRepository

        return try await Task.detached(priority: .userInitiated) {
            try await Device.withDefaultDevice(.gpu) {
                let model = modelBox.value
                var generationParameters = model.defaultGenerationParameters
                generationParameters.maxTokens = settings.maxTokens
                generationParameters.temperature = Float(settings.temperature)
                generationParameters.topP = Float(settings.topP)
                let voiceArgument = QwenVoiceArgumentBuilder.voiceArgument(
                    voice: voice,
                    emotion: emotion,
                    sourceRepository: sourceRepository
                )

                print(
                    """
                    [TuringTTS] Qwen generation starting
                      textCharacters: \(trimmed.count)
                      language: \(settings.language)
                      maxTokens: \(settings.maxTokens)
                      voiceArgument: \(voiceArgument ?? "nil")
                    """
                )

                let audio = try await model.generate(
                    text: trimmed,
                    voice: voiceArgument,
                    refAudio: nil,
                    refText: nil,
                    language: settings.language,
                    generationParameters: generationParameters
                )

                let samples = audio.asArray(Float.self)

                print(
                    """
                    [TuringTTS] Qwen generation finished
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

enum QwenVoiceArgumentBuilder {
    nonisolated static func voiceArgument(
        voice: TuringVoiceDescriptor,
        emotion: String,
        sourceRepository: String
    ) -> String? {
        let lowerSource = sourceRepository.lowercased()
        guard lowerSource.contains("customvoice") ||
              lowerSource.contains("voicedesign") else {
            return nil
        }

        guard voice.resourcePath.hasPrefix("qwen-preset:") else {
            return nil
        }

        let preset = String(
            voice.resourcePath.dropFirst("qwen-preset:".count)
        )
        let trimmedEmotion = emotion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return trimmedEmotion.isEmpty
            ? preset
            : "\(preset), \(trimmedEmotion)"
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
        bundle: Bundle = .main
    ) {
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
