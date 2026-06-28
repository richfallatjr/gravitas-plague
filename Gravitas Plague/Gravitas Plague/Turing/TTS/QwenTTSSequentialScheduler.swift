import Foundation

actor QwenTTSSequentialScheduler {
    private let host: QwenTTSModelHost
    private let cache: TuringAudioCache
    private let fileWriter: TuringAudioFileWriter
    private let settings: QwenGenerationSettings

    init(
        host: QwenTTSModelHost,
        cache: TuringAudioCache,
        fileWriter: TuringAudioFileWriter,
        settings: QwenGenerationSettings
    ) {
        self.host = host
        self.cache = cache
        self.fileWriter = fileWriter
        self.settings = settings
    }

    func render(
        segment: TuringSpeechSegment,
        segmentIndex: Int,
        voice: TuringVoiceDescriptor,
        radioTreatment: TuringRadioEffectProfile?
    ) async throws -> TuringRenderedSegment {
        try Task.checkCancellation()

        let key = try await cache.key(
            segment: segment,
            voice: voice,
            model: host,
            settings: settings,
            radioTreatment: radioTreatment
        )

        if let cached = try await cache.lookup(key: key) {
            return TuringRenderedSegment(
                segmentIndex: segmentIndex,
                fileURL: cached.fileURL,
                durationSeconds: cached.durationSeconds,
                cacheKey: key
            )
        }

        try await host.assertGPUAvailable()
        try await host.loadIfNeeded()

        let session = try await host.makeSession()
        do {
            let waveform = try await session.synthesize(
                text: segment.text,
                emotion: segment.emotion,
                voice: voice,
                settings: settings
            )
            let file = try await fileWriter.write(
                waveform: waveform,
                cacheKey: key
            )
            try await cache.store(file: file, key: key)
            await session.releaseTransientState()

            return TuringRenderedSegment(
                segmentIndex: segmentIndex,
                fileURL: file.fileURL,
                durationSeconds: file.durationSeconds,
                cacheKey: key
            )
        } catch {
            await session.releaseTransientState()
            throw error
        }
    }
}
