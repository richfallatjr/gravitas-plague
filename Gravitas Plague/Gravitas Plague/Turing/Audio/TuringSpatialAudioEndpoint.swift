import Foundation
import RealityKit

actor TuringSpatialAudioEndpoint: TuringTransientAudioPlaybackEndpoint {
    private let loader: TuringRealityAudioResourceLoader
    private let sceneBridge: TuringRealityKitAudioSceneBridge
    private let eventHub: TuringAudioEventHub

    init(
        loader: TuringRealityAudioResourceLoader,
        sceneBridge: TuringRealityKitAudioSceneBridge,
        eventHub: TuringAudioEventHub
    ) {
        self.loader = loader
        self.sceneBridge = sceneBridge
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
            let handle = try await sceneBridge.start(
                prepared: prepared,
                request: request
            )
            await eventHub.yield(.started(handle))
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

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        await sceneBridge.stop(handle)
        await eventHub.yield(.cancelled(handle, reason: reason))
    }

    func stopAll(reason: String) async {
        await sceneBridge.stopAll(reason: reason)
    }

    func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
        await eventHub.stream()
    }

    func evictTransient(fileURL: URL) async {
        await loader.evictTransient(fileURL: fileURL)
    }
}

@MainActor
enum TuringSpatialAudioEndpointFactory {
    static func make(
        emitter: Entity,
        loader: TuringRealityAudioResourceLoader = .shared
    ) -> TuringSpatialAudioEndpoint {
        let eventHub = TuringAudioEventHub()
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
        return TuringSpatialAudioEndpoint(
            loader: loader,
            sceneBridge: bridge,
            eventHub: eventHub
        )
    }
}
