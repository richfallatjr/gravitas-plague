import Foundation
import RealityKit

actor TuringSpatialAudioEndpoint:
    TuringTransientAudioPlaybackEndpoint,
    TuringPCMStreamingPlaybackEndpoint
{
    private let loader: TuringRealityAudioResourceLoader
    private let sceneBridge: TuringRealityKitAudioSceneBridge
    private let pcmSceneBridge: TuringRealityKitPCMStreamBridge
    private let pcmProducerStore: TuringPCMStreamProducerStore
    private let eventHub: TuringAudioEventHub

    init(
        loader: TuringRealityAudioResourceLoader,
        sceneBridge: TuringRealityKitAudioSceneBridge,
        pcmSceneBridge: TuringRealityKitPCMStreamBridge,
        pcmProducerStore: TuringPCMStreamProducerStore,
        eventHub: TuringAudioEventHub
    ) {
        self.loader = loader
        self.sceneBridge = sceneBridge
        self.pcmSceneBridge = pcmSceneBridge
        self.pcmProducerStore = pcmProducerStore
        self.eventHub = eventHub
    }

    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle {
        do {
            let prepared = try await loader.load(
                fileURL: request.fileURL,
                shouldLoop: request.shouldLoop,
                cachePolicy: request.cachePolicy
            )
            let start = try await sceneBridge.start(
                prepared: prepared,
                request: request
            )
            await eventHub.yield(
                .started(
                    handle: start.handle,
                    clockOrigin: start.clockOrigin
                )
            )
            return start.handle
        } catch {
            await eventHub.yield(
                .failed(
                    requestID: request.requestID,
                    runID: request.runID,
                    message: error.localizedDescription
                )
            )
            throw error
        }
    }

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        if await pcmProducerStore.containsActive(handle) {
            let stopped = await pcmSceneBridge.stop(handle)
            await pcmProducerStore.cancel(handle)
            if stopped {
                await eventHub.yield(.cancelled(handle, reason: reason))
            }
            return
        }
        await sceneBridge.stop(handle)
        await eventHub.yield(.cancelled(handle, reason: reason))
    }

    func pause(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async throws {
        if await pcmProducerStore.containsActive(handle) {
            let instant = try await pcmSceneBridge.pause(handle)
            await eventHub.yield(
                .paused(
                    handle: handle,
                    instant: instant,
                    reason: reason
                )
            )
            return
        }
        let instant = try await sceneBridge.pause(handle)
        await eventHub.yield(
            .paused(
                handle: handle,
                instant: instant,
                reason: reason
            )
        )
    }

    func resume(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async throws {
        if await pcmProducerStore.containsActive(handle) {
            let instant = try await pcmSceneBridge.resume(handle)
            await eventHub.yield(
                .resumed(
                    handle: handle,
                    instant: instant,
                    reason: reason
                )
            )
            return
        }
        let instant = try await sceneBridge.resume(handle)
        await eventHub.yield(
            .resumed(
                handle: handle,
                instant: instant,
                reason: reason
            )
        )
    }

    func stopAll(reason: String) async {
        await pcmSceneBridge.stopAll(reason: reason)
        await pcmProducerStore.cancelAll()
        await sceneBridge.stopAll(reason: reason)
    }

    func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
        await eventHub.stream()
    }

    func evictTransient(fileURL: URL) async {
        await loader.evictTransient(fileURL: fileURL)
    }

    func openPCMStream(
        _ request: TuringPCMStreamRequest
    ) async throws -> TuringAudioPlaybackHandle {
        do {
            try request.configuration.validate()
            let buffer = try TuringPCMStreamBuffer(
                configuration: request.configuration
            )
            let converter = try TuringPCMStreamRateConverter(
                sourceSampleRate:
                    request.configuration.sourceSampleRate
            )
            let handle = try await pcmSceneBridge.prepare(
                request: request,
                buffer: buffer
            )
            do {
                try await pcmProducerStore.install(
                    handle: handle,
                    configuration: request.configuration,
                    buffer: buffer,
                    converter: converter
                )
            } catch {
                _ = await pcmSceneBridge.stop(handle)
                throw error
            }
            return handle
        } catch {
            await eventHub.yield(
                .failed(
                    requestID: request.requestID,
                    runID: request.runID,
                    message: error.localizedDescription
                )
            )
            throw error
        }
    }

    func appendPCMStream(
        _ chunk: TuringPCMStreamChunk,
        to handle: TuringAudioPlaybackHandle
    ) async throws -> TuringPCMStreamAppendReceipt {
        let receipt = try await pcmProducerStore.append(
            chunk,
            to: handle
        )
        if receipt.playbackStartRequested {
            _ = try await pcmSceneBridge.startIfReady(
                handle,
                force: false
            )
        }
        return receipt
    }

    func sealPCMStream(
        _ handle: TuringAudioPlaybackHandle
    ) async throws {
        try await pcmProducerStore.seal(handle)
        _ = try await pcmSceneBridge.startIfReady(
            handle,
            force: true
        )
    }

    func pcmStreamMetrics(
        _ handle: TuringAudioPlaybackHandle
    ) async -> TuringPCMStreamMetrics? {
        await pcmProducerStore.metrics(handle)
    }
}

@MainActor
enum TuringSpatialAudioEndpointFactory {
    static func make(
        emitter: Entity,
        loader: TuringRealityAudioResourceLoader = .shared
    ) -> TuringSpatialAudioEndpoint {
        let eventHub = TuringAudioEventHub()
        let pcmProducerStore = TuringPCMStreamProducerStore()
        let bridge = TuringRealityKitAudioSceneBridge(
            emitter: emitter,
            completionSink: { handle, successfully in
                Task {
                    await eventHub.yield(
                        .completed(handle, successfully: successfully)
                    )
                }
            }
        )
        let pcmBridge = TuringRealityKitPCMStreamBridge(
            emitter: emitter,
            startSink: { handle, clockOrigin in
                await eventHub.yield(
                    .started(
                        handle: handle,
                        clockOrigin: clockOrigin
                    )
                )
            },
            completionSink: { handle, successfully in
                await pcmProducerStore.finish(handle)
                await eventHub.yield(
                    .completed(
                        handle,
                        successfully: successfully
                    )
                )
            }
        )
        return TuringSpatialAudioEndpoint(
            loader: loader,
            sceneBridge: bridge,
            pcmSceneBridge: pcmBridge,
            pcmProducerStore: pcmProducerStore,
            eventHub: eventHub
        )
    }
}
