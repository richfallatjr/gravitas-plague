import Foundation

actor Chapter02PrerecordingPlayer {
    private let endpoint: any TuringAudioPlaybackEndpoint
    private var activeHandle: TuringAudioPlaybackHandle?

    init(
        endpoint: any TuringAudioPlaybackEndpoint =
            TuringGlobalAudioPlayerActor()
    ) {
        self.endpoint = endpoint
    }

    func play(
        resourcePath: String,
        runID: String,
        label: String,
        gainDB: Float = -5
    ) async throws {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath: resourcePath
        )
        let events = await endpoint.events()
        let requestID = UUID()
        let handle = try await endpoint.play(
            TuringAudioPlaybackRequest(
                requestID: requestID,
                runID: runID,
                fileURL: url,
                kind: .prerecording,
                route: .richGlobal,
                label: label,
                gainDB: gainDB,
                shouldLoop: false,
                cachePolicy: .bundled
            )
        )
        activeHandle = handle
        for await event in events {
            switch event {
            case .completed(let returned, let successfully)
                where returned == handle:
                activeHandle = nil
                guard successfully else {
                    throw TuringRuntimeError.invalidConfig(
                        "Chapter 2 prerecording failed: \(label)."
                    )
                }
                return
            case .failed(let failedRequestID, let failedRunID, let message)
                where failedRequestID == requestID && failedRunID == runID:
                activeHandle = nil
                throw TuringRuntimeError.invalidConfig(message)
            case .cancelled(let returned, let reason) where returned == handle:
                activeHandle = nil
                throw TuringRuntimeError.invalidConfig(
                    "Chapter 2 prerecording was cancelled: \(reason)"
                )
            default:
                continue
            }
        }
        throw TuringRuntimeError.invalidConfig(
            "Chapter 2 prerecording event stream ended: \(label)."
        )
    }

    func cancel(reason: String) async {
        guard let activeHandle else { return }
        self.activeHandle = nil
        await endpoint.stop(activeHandle, reason: reason)
    }
}
