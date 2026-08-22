@preconcurrency import RealityKit
import Foundation

@MainActor
final class StoryAmbientAircraftWorldBridge {
    private struct Active {
        let sessionID: StoryAmbientAircraftSessionID
        let eventID: StoryAmbientAircraftEventID
        let emitter: Entity
        let controller: AudioPlaybackController
        let continuation: CheckedContinuation<Void, Error>
    }

    private weak var sceneRoot: Entity?
    private var active: Active?

    func bind(sceneRoot: Entity) {
        stopActive(reason: "sceneRootRebound")
        self.sceneRoot = sceneRoot
    }

    func unbind(reason: String) {
        stopActive(reason: reason)
        sceneRoot = nil
    }

    func playAndWait(
        prepared: TuringPreparedRealityAudioResource,
        request: StoryAmbientAircraftPlaybackRequest
    ) async throws {
        guard active == nil else {
            throw StoryAmbientAircraftError.voiceLimitExceeded
        }
        guard let sceneRoot else {
            throw StoryAmbientAircraftError.sceneUnavailable
        }

        let emitter = Entity()
        emitter.name = "StoryAmbientAircraft_\(request.eventID.rawValue.uuidString)"
        emitter.position = sceneRoot.convert(position: request.worldPosition, from: nil)
        emitter.components.set(
            SpatialAudioComponent(
                gain: .zero,
                directLevel: .zero,
                reverbLevel: .zero,
                directivity: .beam(focus: .zero),
                distanceAttenuation: .rolloff(
                    factor: request.distanceRolloffFactor
                )
            )
        )
        sceneRoot.addChild(emitter)

        let controller = emitter.prepareAudio(prepared.resource)
        controller.gain = request.sourceGainDB

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                active = Active(
                    sessionID: request.sessionID,
                    eventID: request.eventID,
                    emitter: emitter,
                    controller: controller,
                    continuation: continuation
                )
                controller.completionHandler = { [weak self] in
                    Task { @MainActor in
                        self?.complete(
                            sessionID: request.sessionID,
                            eventID: request.eventID
                        )
                    }
                }
                controller.play()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop(
                    sessionID: request.sessionID,
                    eventID: request.eventID,
                    reason: "taskCancelled"
                )
            }
        }
    }

    func stopActive(reason: String) {
        guard let active else { return }
        stop(
            sessionID: active.sessionID,
            eventID: active.eventID,
            reason: reason
        )
    }

    private func complete(
        sessionID: StoryAmbientAircraftSessionID,
        eventID: StoryAmbientAircraftEventID
    ) {
        guard let active,
              active.sessionID == sessionID,
              active.eventID == eventID else { return }
        active.controller.completionHandler = nil
        active.emitter.removeFromParent()
        self.active = nil
        active.continuation.resume()
    }

    private func stop(
        sessionID: StoryAmbientAircraftSessionID,
        eventID: StoryAmbientAircraftEventID,
        reason: String
    ) {
        guard let active,
              active.sessionID == sessionID,
              active.eventID == eventID else { return }
        active.controller.completionHandler = nil
        active.controller.stop()
        active.emitter.removeFromParent()
        self.active = nil
        active.continuation.resume(throwing: CancellationError())
        print(
            "[StoryAmbientAircraft] active event stopped " +
                "eventID=\(eventID.rawValue.uuidString) reason=\(reason)"
        )
    }
}
