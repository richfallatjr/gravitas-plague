import Foundation

actor TuringDebugHarness {
    private let scheduler: QwenTTSSequentialScheduler
    private let voices: TuringVoiceRegistry

    init(
        scheduler: QwenTTSSequentialScheduler,
        voices: TuringVoiceRegistry
    ) {
        self.scheduler = scheduler
        self.voices = voices
    }

    func generatePhase0Line() async throws -> TuringRenderedSegment {
        let voice = try await voices.voice(id: "phase0_ryan_dev")
        let segment = TuringSpeechSegment(
            text: "If you can hear this, keep the radio close.",
            emotion: "urgent, low radio warning"
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
                maxTokens: config.tts.maxTokens,
                seed: nil
            )
        )

        return TuringDebugHarness(
            scheduler: scheduler,
            voices: voiceRegistry
        )
    }
}
