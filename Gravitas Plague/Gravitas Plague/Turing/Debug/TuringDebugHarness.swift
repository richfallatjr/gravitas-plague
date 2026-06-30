import Foundation

actor TuringDebugHarness {
    private let scheduler: QwenTTSSequentialScheduler
    private let smokeRequest: QwenPhase0SmokeRequest
    private let model: TuringModelDescriptor
    private let canaryStore: QwenPhase0CanaryStore

    init(
        scheduler: QwenTTSSequentialScheduler,
        smokeRequest: QwenPhase0SmokeRequest,
        model: TuringModelDescriptor,
        canaryStore: QwenPhase0CanaryStore
    ) {
        self.scheduler = scheduler
        self.smokeRequest = smokeRequest
        self.model = model
        self.canaryStore = canaryStore
    }

    func generatePhase0Line() async throws -> TuringRenderedSegment {
        let report = try await canaryStore.load()
        guard report?.matches(
            model: model,
            smokeRequest: smokeRequest
        ) == true else {
            throw TuringRuntimeError.qwenModelLoadFailed(
                "Generate + Play disabled: Qwen Phase 0 canary has not passed for this model/package/build tuple."
            )
        }

        return try await scheduler.renderPhase0BareBaseSmoke(
            request: smokeRequest
        )
    }

    func loadCanaryReport() async throws -> QwenPhase0CanaryReport? {
        try await canaryStore.load()
    }

    func canaryPassedForActiveTuple() async throws -> Bool {
        try await canaryStore.load()?.matches(
            model: model,
            smokeRequest: smokeRequest
        ) == true
    }

    func runPhase0NativeCanary() async throws -> TuringRenderedSegment {
        let baseReport = QwenPhase0CanaryIdentity.makeReport(
            model: model,
            smokeRequest: smokeRequest
        )

        do {
            try await canaryStore.markStarted(
                .fullGenerate,
                report: baseReport
            )

            let rendered = try await scheduler.renderPhase0BareBaseSmoke(
                request: smokeRequest
            )

            try await canaryStore.markCompleted(.writeWav)
            try await canaryStore.markPassed(finalStage: .writeWav)

            print(
                """
                [TuringTTS] Qwen Phase 0 canary passed
                  lastCompletedStage: writeWav
                  durationSeconds: \(rendered.durationSeconds)
                  file: \(rendered.fileURL.path)
                """
            )

            return rendered
        } catch {
            try? await canaryStore.markFailed(
                stage: .fullGenerate,
                error: error
            )
            throw error
        }
    }

    func cleanupRenderedSegment(
        _ rendered: TuringRenderedSegment,
        reason: String
    ) async {
        await scheduler.deleteTransientRenderedSegment(
            rendered,
            reason: reason
        )
    }

    func cleanupTransientAudio(
        reason: String
    ) async {
        await scheduler.cleanupTransientAudio(
            reason: reason
        )
    }

    func runNoCacheMemorySoak(
        iterations: Int
    ) async throws -> TuringSoakTestResult {
        let runner = TuringSoakTestRunner(
            scheduler: scheduler
        )
        return try await runner.run(
            iterations: iterations
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
        let model = try await modelRegistry.model(id: config.tts.modelID)
        let host = QwenMLXAudioModelHost(
            descriptor: model,
            runtime: config,
            bundle: bundle
        )

        let transientRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TuringTransientAudio",
                isDirectory: true
            )
        let transientFiles = TuringTransientAudioFileStore(
            rootURL: transientRoot
        )
        await transientFiles.cleanupAll(
            reason: "appLaunch"
        )

        let transientWriterRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TuringTransientAudioWriter",
                isDirectory: true
            )

        let scheduler = QwenTTSSequentialScheduler(
            host: host,
            fileWriter: TuringAudioFileWriter(rootURL: transientWriterRoot),
            transientFiles: transientFiles,
            memoryProbe: TuringMemoryFootprintProbe(),
            cleanup: TuringQwenTransientCleanup(),
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
            smokeRequest: QwenPhase0SmokeRequest(
                text: config.debug.phase0SmokeText,
                language: config.tts.language,
                maxTokens: config.tts.maxTokens,
                temperature: Float(config.tts.temperature),
                topP: Float(config.tts.topP),
                repetitionPenalty: Float(config.tts.repetitionPenalty)
            ),
            model: model,
            canaryStore: try QwenPhase0CanaryStore(
                url: QwenPhase0CanaryStore.defaultURL()
            )
        )
    }
}
