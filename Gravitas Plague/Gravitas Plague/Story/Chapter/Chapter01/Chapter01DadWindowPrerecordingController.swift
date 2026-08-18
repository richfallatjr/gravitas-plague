import AVFoundation
import Foundation

actor Chapter01DadWindowPrerecordingController {
    enum PlaybackError: LocalizedError {
        case notPrepared
        case invalidDuration
        case interrupted(String)

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "Dad-window Rich prerecording is not prepared."
            case .invalidDuration:
                return "Dad-window Rich prerecording has no playable duration."
            case .interrupted(let reason):
                return "Dad-window Rich prerecording was interrupted: \(reason)"
            }
        }
    }

    static let resourcePath =
        "Turing/Audio/prerecordings/pr-rich-dad-window-01.mp3"
    static let desiredCompletionAfterExitWalkStartSeconds: TimeInterval = 2
    static let gainDecibels: Float = -5

    private let endpoint: any TuringAudioPlaybackEndpoint
    private var preparedURL: URL?
    private var preparedDurationSeconds: TimeInterval?
    private var activeHandle: TuringAudioPlaybackHandle?

    init(
        endpoint: any TuringAudioPlaybackEndpoint =
            TuringGlobalAudioPlayerActor()
    ) {
        self.endpoint = endpoint
    }

    @discardableResult
    func prepare() throws -> TimeInterval {
        if let preparedDurationSeconds {
            return preparedDurationSeconds
        }

        let url = try TuringResourceLoader.resourceURL(
            resourcePath: Self.resourcePath
        )
        let validator = try AVAudioPlayer(contentsOf: url)
        guard validator.duration > 0 else {
            throw PlaybackError.invalidDuration
        }

        preparedURL = url
        preparedDurationSeconds = validator.duration
        print("""
        [Chapter01DadPR] prepared
          file: \(url.lastPathComponent)
          durationSeconds: \(validator.duration)
          route: richGlobal
          gainDB: \(Self.gainDecibels)
        """)
        return validator.duration
    }

    func scheduledStartDelaySeconds(
        centeredIdleDurationSeconds: TimeInterval,
        exitTurnDurationSeconds: TimeInterval
    ) throws -> TimeInterval {
        guard let preparedDurationSeconds else {
            throw PlaybackError.notPrepared
        }
        return Self.scheduledStartDelaySeconds(
            audioDurationSeconds: preparedDurationSeconds,
            centeredIdleDurationSeconds: centeredIdleDurationSeconds,
            exitTurnDurationSeconds: exitTurnDurationSeconds,
            desiredCompletionAfterExitWalkStartSeconds:
                Self.desiredCompletionAfterExitWalkStartSeconds
        )
    }

    nonisolated static func scheduledStartDelaySeconds(
        audioDurationSeconds: TimeInterval,
        centeredIdleDurationSeconds: TimeInterval,
        exitTurnDurationSeconds: TimeInterval,
        desiredCompletionAfterExitWalkStartSeconds: TimeInterval
    ) -> TimeInterval {
        max(
            0,
            centeredIdleDurationSeconds +
                exitTurnDurationSeconds +
                desiredCompletionAfterExitWalkStartSeconds -
                audioDurationSeconds
        )
    }

    func playScheduled(
        after delaySeconds: TimeInterval,
        chapterRunID: UUID
    ) async throws {
        try await withTaskCancellationHandler {
            try await Task.sleep(
                for: .seconds(max(0, delaySeconds))
            )
            try Task.checkCancellation()
            guard let preparedURL else {
                throw PlaybackError.notPrepared
            }

            let events = await endpoint.events()
            let requestID = UUID()
            let runID = "chapter01.dadWindow.\(chapterRunID.uuidString)"
            let handle = try await endpoint.play(
                TuringAudioPlaybackRequest(
                    requestID: requestID,
                    runID: runID,
                    fileURL: preparedURL,
                    kind: .prerecording,
                    route: .richGlobal,
                    label: "chapter01.dadWindow.richPR",
                    gainDB: Self.gainDecibels,
                    shouldLoop: false,
                    cachePolicy: .bundled
                )
            )
            activeHandle = handle
            print("""
            [Chapter01DadPR] started
              chapterRunID: \(chapterRunID.uuidString)
              delayAfterCenteredIdleStartedSeconds: \(delaySeconds)
              desiredCompletionAfterExitWalkStartSeconds: \(Self.desiredCompletionAfterExitWalkStartSeconds)
            """)

            try await awaitCompletion(
                events: events,
                handle: handle,
                requestID: requestID,
                runID: runID
            )
        } onCancel: {
            Task {
                await self.cancel(reason: "scheduledPlaybackTaskCancelled")
            }
        }
    }

    func cancel(reason: String) async {
        guard let activeHandle else { return }
        self.activeHandle = nil
        await endpoint.stop(activeHandle, reason: reason)
    }

    private func awaitCompletion(
        events: AsyncStream<TuringAudioPlaybackEvent>,
        handle: TuringAudioPlaybackHandle,
        requestID: UUID,
        runID: String
    ) async throws {
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .completed(let completedHandle, let successfully):
                guard completedHandle == handle else { continue }
                activeHandle = nil
                guard successfully else {
                    throw PlaybackError.interrupted(
                        "completionCallbackUnsuccessful"
                    )
                }
                print("[Chapter01DadPR] completed chapterRunID=\(runID)")
                return

            case .failed(let failedRequestID, let failedRunID, let message):
                guard failedRequestID == requestID,
                      failedRunID == runID else {
                    continue
                }
                activeHandle = nil
                throw PlaybackError.interrupted(message)

            case .cancelled(let cancelledHandle, let reason):
                guard cancelledHandle == handle else { continue }
                activeHandle = nil
                throw PlaybackError.interrupted(reason)

            case .started, .paused, .resumed:
                continue
            }
        }

        activeHandle = nil
        throw PlaybackError.interrupted("playbackEventStreamEnded")
    }
}
