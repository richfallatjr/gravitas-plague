import Foundation

actor QwenTTSSequentialScheduler {
    private let host: QwenTTSModelHost
    private let fileWriter: TuringAudioFileWriter
    private let transientFiles: TuringTransientAudioFileStore
    private let memoryProbe: TuringMemoryFootprintProbe?
    private let cleanup: TuringQwenTransientCleanup
    private let settings: QwenGenerationSettings

    init(
        host: QwenTTSModelHost,
        fileWriter: TuringAudioFileWriter,
        transientFiles: TuringTransientAudioFileStore,
        memoryProbe: TuringMemoryFootprintProbe?,
        cleanup: TuringQwenTransientCleanup,
        settings: QwenGenerationSettings
    ) {
        self.host = host
        self.fileWriter = fileWriter
        self.transientFiles = transientFiles
        self.memoryProbe = memoryProbe
        self.cleanup = cleanup
        self.settings = settings
    }

    func renderPhase0BareBaseSmoke(
        request: QwenPhase0SmokeRequest
    ) async throws -> TuringRenderedSegment {
        try await renderNoCacheBareBase(
            request: request,
            purpose: "phase0NativeCanary",
            segmentIndex: 0
        )
    }

    func renderNoCacheBareBase(
        request: QwenPhase0SmokeRequest,
        purpose: String,
        segmentIndex: Int
    ) async throws -> TuringRenderedSegment {
        try Task.checkCancellation()

        print(
            """
            [TuringTTS] Qwen canary entering public generate
              purpose: \(purpose)
              segmentIndex: \(segmentIndex)
              persistentAudioCache: false
              transientPlaybackFile: true
              voiceArgument: nil
              refAudio: nil
              refText: nil
            """
        )

        let before = await memoryProbe?.snapshot(
            label: "beforeRender",
            segmentIndex: segmentIndex
        )

        let waveform: QwenWaveform
        do {
            waveform = try await host.generatePhase0BareBaseSmoke(
                request
            )
        } catch is CancellationError {
            await cleanup.releaseTransientState(
                reason: "renderCancelled"
            )
            _ = await memoryProbe?.snapshot(
                label: "afterCancelledCleanup",
                segmentIndex: segmentIndex
            )
            throw CancellationError()
        } catch {
            await cleanup.releaseTransientState(
                reason: "synthesisFailed"
            )
            _ = await memoryProbe?.snapshot(
                label: "afterFailedCleanup",
                segmentIndex: segmentIndex
            )
            throw error
        }
        try Task.checkCancellation()

        let stored: TuringTransientAudioFileStore.StoredFile
        do {
            stored = try await transientFiles.write(
                waveform: waveform,
                purpose: purpose,
                segmentIndex: segmentIndex,
                writer: fileWriter
            )
        } catch {
            await cleanup.releaseTransientState(
                reason: "fileWriteFailed"
            )
            _ = await memoryProbe?.snapshot(
                label: "afterFileWriteFailedCleanup",
                segmentIndex: segmentIndex
            )
            throw error
        }

        await cleanup.releaseTransientState(
            reason: "renderCompleted"
        )

        let after = await memoryProbe?.snapshot(
            label: "afterRenderCleanup",
            segmentIndex: segmentIndex
        )

        if let before, let after {
            print(
                """
                [TuringMemory] Qwen render cleanup delta
                  segmentIndex: \(segmentIndex)
                  beforePhysFootprint: \(before.physFootprintBytes)
                  afterPhysFootprint: \(after.physFootprintBytes)
                  deltaBytes: \(Int64(after.physFootprintBytes) - Int64(before.physFootprintBytes))
                """
            )
        }

        return TuringRenderedSegment(
            segmentIndex: segmentIndex,
            renderID: stored.id,
            fileURL: stored.fileURL,
            durationSeconds: stored.durationSeconds,
            isTransient: true,
            sampleRate: stored.sampleRate,
            channelCount: stored.channelCount,
            cacheKey: stored.id
        )
    }

    func render(
        segment: TuringSpeechSegment,
        segmentIndex: Int,
        voice: TuringVoiceDescriptor,
        radioTreatment: TuringRadioEffectProfile?
    ) async throws -> TuringRenderedSegment {
        try Task.checkCancellation()

        print(
            """
            [TuringTTS] Qwen no-cache render requested
              purpose: speechSegment
              segmentIndex: \(segmentIndex)
              persistentAudioCache: false
              voiceArgument: nil
              refAudio: nil
              refText: nil
            """
        )

        try await host.assertGPUAvailable()
        try await host.loadIfNeeded()

        let session = try await host.makeSession()
        let before = await memoryProbe?.snapshot(
            label: "beforeRender",
            segmentIndex: segmentIndex
        )

        do {
            try Task.checkCancellation()
            let waveform = try await session.synthesize(
                text: segment.text,
                emotion: segment.emotion,
                voice: voice,
                settings: settings
            )
            try Task.checkCancellation()

            let stored = try await transientFiles.write(
                waveform: waveform,
                purpose: "speechSegment",
                segmentIndex: segmentIndex,
                writer: fileWriter
            )
            await session.releaseTransientState()
            await cleanup.releaseTransientState(
                reason: "renderCompleted"
            )

            let after = await memoryProbe?.snapshot(
                label: "afterRenderCleanup",
                segmentIndex: segmentIndex
            )

            if let before, let after {
                print(
                    """
                    [TuringMemory] Qwen render cleanup delta
                      segmentIndex: \(segmentIndex)
                      beforePhysFootprint: \(before.physFootprintBytes)
                      afterPhysFootprint: \(after.physFootprintBytes)
                      deltaBytes: \(Int64(after.physFootprintBytes) - Int64(before.physFootprintBytes))
                    """
                )
            }

            return TuringRenderedSegment(
                segmentIndex: segmentIndex,
                renderID: stored.id,
                fileURL: stored.fileURL,
                durationSeconds: stored.durationSeconds,
                isTransient: true,
                sampleRate: stored.sampleRate,
                channelCount: stored.channelCount,
                cacheKey: stored.id
            )
        } catch is CancellationError {
            await session.releaseTransientState()
            await cleanup.releaseTransientState(
                reason: "renderCancelled"
            )
            _ = await memoryProbe?.snapshot(
                label: "afterCancelledCleanup",
                segmentIndex: segmentIndex
            )
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Qwen synthesis cancelled and cleaned up."
            )
        } catch {
            await session.releaseTransientState()
            await cleanup.releaseTransientState(
                reason: "synthesisFailed"
            )
            _ = await memoryProbe?.snapshot(
                label: "afterFailedCleanup",
                segmentIndex: segmentIndex
            )
            throw error
        }
    }

    func deleteTransientRenderedSegment(
        _ segment: TuringRenderedSegment,
        reason: String
    ) async {
        guard segment.isTransient else {
            return
        }

        await transientFiles.delete(
            renderedSegment: segment,
            reason: reason
        )
    }

    func cleanupTransientAudio(
        reason: String
    ) async {
        await transientFiles.cleanupAll(
            reason: reason
        )
    }
}
