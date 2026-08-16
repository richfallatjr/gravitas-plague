import Foundation
import RealityKit

@MainActor
final class StorySpatialPrerecordingPlayer {
    private var controller: AudioPlaybackController?
    private var preparedResource: AudioFileResource?
    private weak var emitter: Entity?
    private var activeRunID: UUID?
    private var gainDB: Float = 0

    var onCompleted: ((UUID, Bool) -> Void)?

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

    func play(runID: UUID) throws {
        guard activeRunID == runID,
              controller == nil,
              let preparedResource,
              let emitter,
              emitter.parent != nil else {
            throw Chapter03Error.angelPrerecordingInvalid(
                "prepared cinematic recording is unavailable"
            )
        }
        let controller = emitter.playAudio(preparedResource)
        controller.gain = Double(gainDB)
        self.controller = controller
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.complete(runID: runID)
            }
        }
        print(
            "[StoryCinematicPR] actual playback started " +
                "runID=\(runID.uuidString) gainDB=\(gainDB)"
        )
    }

    func stop(reason: String) {
        controller?.completionHandler = nil
        controller?.stop()
        controller = nil
        preparedResource = nil
        emitter = nil
        activeRunID = nil
        print("[StoryCinematicPR] stopped reason=\(reason)")
    }

    var activePlaybackControllerCount: Int {
        controller == nil ? 0 : 1
    }

    private func complete(runID: UUID) {
        guard activeRunID == runID, let controller else { return }
        controller.completionHandler = nil
        self.controller = nil
        print(
            "[StoryCinematicPR] actual playback completed " +
                "runID=\(runID.uuidString)"
        )
        onCompleted?(runID, true)
    }
}
