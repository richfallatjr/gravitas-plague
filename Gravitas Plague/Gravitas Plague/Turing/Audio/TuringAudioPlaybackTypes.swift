import Foundation

nonisolated enum TuringWalkieAudioError: LocalizedError {
    case missingWalkieEmitter
    case playbackStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWalkieEmitter:
            return "Story walkie audio emitter is not installed."
        case .playbackStartFailed(let label):
            return "Story walkie playback failed to start: \(label)."
        }
    }
}

nonisolated enum TuringAudioClipKind: String, Sendable, Hashable {
    case generated
    case prerecording
    case filler
    case commSFX
    case ambientStatic
    case sendingStatic
    case radioCue
    case radioBroadcast
}

nonisolated enum TuringAudioRouteID: String, Sendable, Hashable {
    case storyWalkie
    case richHeadTracked
    case richGlobal
    case rollingBenchRadio
}

nonisolated enum TuringAudioResourceCachePolicy: String, Sendable, Hashable {
    case bundled
    case transient
    case none
}

nonisolated struct TuringAudioPlaybackRequest: Sendable, Hashable {
    let requestID: UUID
    let runID: String
    let fileURL: URL
    let kind: TuringAudioClipKind
    let route: TuringAudioRouteID
    let label: String
    let gainDB: Float
    let shouldLoop: Bool
    let cachePolicy: TuringAudioResourceCachePolicy
}

nonisolated struct TuringAudioPlaybackHandle: Hashable, Sendable {
    let id: UUID
    let requestID: UUID
    let runID: String
    let route: TuringAudioRouteID
}

nonisolated enum TuringAudioPlaybackEvent: Sendable, Equatable {
    case started(TuringAudioPlaybackHandle)
    case completed(TuringAudioPlaybackHandle, successfully: Bool)
    case failed(requestID: UUID, runID: String, message: String)
    case cancelled(TuringAudioPlaybackHandle, reason: String)
}

nonisolated protocol TuringAudioPlaybackEndpoint: Sendable {
    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async

    func events() async -> AsyncStream<TuringAudioPlaybackEvent>
}

actor TuringUnavailableAudioEndpoint: TuringAudioPlaybackEndpoint {
    private let message: String
    private let eventHub = TuringAudioEventHub()

    init(message: String) {
        self.message = message
    }

    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle {
        await eventHub.yield(
            .failed(
                requestID: request.requestID,
                runID: request.runID,
                message: message
            )
        )
        throw TuringRuntimeError.invalidConfig(message)
    }

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {}

    func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
        await eventHub.stream()
    }
}
