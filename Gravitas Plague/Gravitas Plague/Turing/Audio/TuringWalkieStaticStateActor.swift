import Foundation

actor TuringWalkieStaticStateActor {
    private enum Gain {
        static let ambientDB: Float = -23
        static let sendingDB: Float = -16.5
    }

    private let endpoint: any TuringAudioPlaybackEndpoint
    private var ambientHandle: TuringAudioPlaybackHandle?
    private var sendingHandle: TuringAudioPlaybackHandle?

    init(endpoint: any TuringAudioPlaybackEndpoint) {
        self.endpoint = endpoint
    }

    func startAmbient(fileURL: URL, runID: String) async throws {
        guard ambientHandle == nil else { return }
        ambientHandle = try await endpoint.play(
            .init(
                requestID: UUID(),
                runID: runID,
                fileURL: fileURL,
                kind: .ambientStatic,
                route: .storyWalkie,
                label: "ambientStatic",
                gainDB: Gain.ambientDB,
                shouldLoop: true,
                cachePolicy: .bundled
            )
        )
    }

    func stopAmbient(reason: String) async {
        guard let handle = ambientHandle else { return }
        ambientHandle = nil
        await endpoint.stop(handle, reason: reason)
    }

    func startSending(fileURL: URL, runID: String) async throws {
        guard sendingHandle == nil else { return }
        sendingHandle = try await endpoint.play(
            .init(
                requestID: UUID(),
                runID: runID,
                fileURL: fileURL,
                kind: .sendingStatic,
                route: .storyWalkie,
                label: "sendingStatic",
                gainDB: Gain.sendingDB,
                shouldLoop: true,
                cachePolicy: .bundled
            )
        )
    }

    func stopSending(reason: String) async {
        guard let handle = sendingHandle else { return }
        sendingHandle = nil
        await endpoint.stop(handle, reason: reason)
    }

    func stopAll(reason: String) async {
        await stopSending(reason: reason)
        await stopAmbient(reason: reason)
    }
}
