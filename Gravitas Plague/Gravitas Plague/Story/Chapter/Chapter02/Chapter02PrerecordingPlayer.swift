import Foundation

@MainActor
final class Chapter02PrerecordingPlayer {
    private let endpoint: any TuringAudioPlaybackEndpoint
    private weak var richVocalChannel:
        (any StoryRichVocalChannelControlling)?
    private var activeHandle: TuringAudioPlaybackHandle?
    private var activeBattleSpeechToken: StoryRichBattleSpeechToken?

    init(
        endpoint: any TuringAudioPlaybackEndpoint =
            TuringGlobalAudioPlayerActor(),
        richVocalChannel:
            (any StoryRichVocalChannelControlling)? = nil
    ) {
        self.endpoint = endpoint
        self.richVocalChannel = richVocalChannel
    }

    func play(
        resourcePath: String,
        runID: String,
        label: String,
        battleInstanceID: UUID? = nil,
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
            case .started(let returned) where returned == handle:
                if let battleInstanceID,
                   activeBattleSpeechToken == nil,
                   let richVocalChannel {
                    activeBattleSpeechToken =
                        richVocalChannel.beginBattleSpeech(
                            battleInstanceID: battleInstanceID,
                            cueID: label,
                            playbackID: handle.id
                        )
                }
            case .completed(let returned, let successfully)
                where returned == handle:
                releaseBattleSpeech(reason: "actualCompletion")
                activeHandle = nil
                guard successfully else {
                    throw TuringRuntimeError.invalidConfig(
                        "Chapter 2 prerecording failed: \(label)."
                    )
                }
                return
            case .failed(let failedRequestID, let failedRunID, let message)
                where failedRequestID == requestID && failedRunID == runID:
                releaseBattleSpeech(reason: "endpointFailure")
                activeHandle = nil
                throw TuringRuntimeError.invalidConfig(message)
            case .cancelled(let returned, let reason) where returned == handle:
                releaseBattleSpeech(reason: "cancelled.\(reason)")
                activeHandle = nil
                throw TuringRuntimeError.invalidConfig(
                    "Chapter 2 prerecording was cancelled: \(reason)"
                )
            default:
                continue
            }
        }
        releaseBattleSpeech(reason: "eventStreamEnded")
        throw TuringRuntimeError.invalidConfig(
            "Chapter 2 prerecording event stream ended: \(label)."
        )
    }

    func cancel(reason: String) async {
        guard let activeHandle else { return }
        self.activeHandle = nil
        await endpoint.stop(activeHandle, reason: reason)
        releaseBattleSpeech(reason: reason)
    }

    private func releaseBattleSpeech(reason: String) {
        guard let activeBattleSpeechToken else { return }
        richVocalChannel?.endBattleSpeech(
            token: activeBattleSpeechToken,
            reason: reason
        )
        self.activeBattleSpeechToken = nil
    }
}
