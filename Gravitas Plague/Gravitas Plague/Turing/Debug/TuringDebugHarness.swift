import Foundation

actor TuringDebugHarness {
    private let scheduler: QwenTTSSequentialScheduler
    private let voices: TuringVoiceRegistry
    private let smokeText: String

    init(
        scheduler: QwenTTSSequentialScheduler,
        voices: TuringVoiceRegistry,
        smokeText: String
    ) {
        self.scheduler = scheduler
        self.voices = voices
        self.smokeText = smokeText
    }

    func generatePhase0Line() async throws -> TuringRenderedSegment {
        let voice = try await voices.voice(id: "qwen_phase0_default")
        let segment = TuringSpeechSegment(
            text: smokeText,
            emotion: "phase0_audio_only_smoke"
        )

        return try await scheduler.render(
            segment: segment,
            segmentIndex: 0,
            voice: voice,
            radioTreatment: nil
        )
    }
}

enum TuringRuntimeFactory {
    nonisolated static func makeDebugHarness(
        bundle: Bundle = .main
    ) async throws -> TuringDebugHarness {
        let config = try TuringResourceLoader.decodeResource(
            TuringRuntimeConfig.self,
            resourcePath: "Turing/Config/turing-runtime.json",
            bundle: bundle
        )
        let modelRegistry = try TuringModelRegistry(bundle: bundle)
        let voiceRegistry = try TuringVoiceRegistry(bundle: bundle)
        let model = try await modelRegistry.model(id: config.tts.modelID)
        let host = QwenMLXAudioModelHost(
            descriptor: model,
            runtime: config,
            bundle: bundle
        )

        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "TuringAudioCache",
            isDirectory: true
        )

        let scheduler = QwenTTSSequentialScheduler(
            host: host,
            cache: TuringAudioCache(rootURL: cacheRoot),
            fileWriter: TuringAudioFileWriter(rootURL: cacheRoot),
            settings: QwenGenerationSettings(
                language: config.tts.language,
                sampleRate: config.tts.sampleRate,
                temperature: config.tts.temperature,
                topP: config.tts.topP,
                repetitionPenalty: config.tts.repetitionPenalty,
                maxTokens: config.tts.maxTokens,
                seed: nil
            )
        )

        return TuringDebugHarness(
            scheduler: scheduler,
            voices: voiceRegistry,
            smokeText: config.debug.phase0SmokeText
        )
    }
}
