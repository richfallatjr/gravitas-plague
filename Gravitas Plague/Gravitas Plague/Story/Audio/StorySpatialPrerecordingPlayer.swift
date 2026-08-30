import Foundation
import RealityKit

nonisolated struct StorySpatialPrerecordingPlaybackStart: Sendable, Equatable {
    let runID: UUID
    let playbackID: UUID
    let clockOrigin: ContinuousClock.Instant
}

@MainActor
final class StorySpatialPrerecordingPlayer {
    private var controller: AudioPlaybackController?
    private var preparedResource: AudioFileResource?
    private weak var emitter: Entity?
    private var activeRunID: UUID?
    private var activePlaybackID: UUID?
    private var clockOrigin: ContinuousClock.Instant?
    private var gainDB: Float = 0

    var onCompleted: ((UUID, UUID, Bool) -> Void)?

    func prepare(
        runID: UUID,
        audioURL: URL,
        emitter: Entity,
        gainDB: Float
    ) async throws {
        stop(reason: "replacement")
        guard emitter.parent != nil else {
            throw Chapter03Error.angelPrerecordingInvalid(
                "cinematic emitter is not installed"
            )
        }
        let resource = try await AudioFileResource(
            contentsOf: audioURL,
            configuration: .init(
                loadingStrategy: .stream,
                shouldLoop: false
            )
        )
        preparedResource = resource
        self.emitter = emitter
        activeRunID = runID
        self.gainDB = gainDB
        print(
            "[StoryCinematicPR] prepared streaming resource " +
                "runID=\(runID.uuidString) file=\(audioURL.lastPathComponent)"
        )
    }

    func play(runID: UUID) throws -> StorySpatialPrerecordingPlaybackStart {
        guard activeRunID == runID,
              controller == nil,
              let preparedResource,
              let emitter,
              emitter.parent != nil else {
            throw Chapter03Error.angelPrerecordingInvalid(
                "prepared cinematic recording is unavailable"
            )
        }
        let playbackID = UUID()
        let controller = emitter.playAudio(preparedResource)
        let clockOrigin = ContinuousClock.now
        controller.gain = Double(gainDB)
        self.controller = controller
        activePlaybackID = playbackID
        self.clockOrigin = clockOrigin
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.complete(runID: runID, playbackID: playbackID)
            }
        }
        print(
            "[StoryCinematicPR] actual playback started " +
                "runID=\(runID.uuidString) playbackID=\(playbackID.uuidString) gainDB=\(gainDB)"
        )
        return StorySpatialPrerecordingPlaybackStart(
            runID: runID,
            playbackID: playbackID,
            clockOrigin: clockOrigin
        )
    }

    func stop(reason: String) {
        controller?.completionHandler = nil
        controller?.stop()
        controller = nil
        preparedResource = nil
        emitter = nil
        activeRunID = nil
        activePlaybackID = nil
        clockOrigin = nil
        print("[StoryCinematicPR] stopped reason=\(reason)")
    }

    var activePlaybackControllerCount: Int {
        controller == nil ? 0 : 1
    }

    private func complete(runID: UUID, playbackID: UUID) {
        guard activeRunID == runID,
              activePlaybackID == playbackID,
              let controller else { return }
        controller.completionHandler = nil
        self.controller = nil
        activePlaybackID = nil
        clockOrigin = nil
        print(
            "[StoryCinematicPR] actual playback completed " +
                "runID=\(runID.uuidString) playbackID=\(playbackID.uuidString)"
        )
        onCompleted?(runID, playbackID, true)
    }
}
