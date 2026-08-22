@preconcurrency import RealityKit
import Foundation

@MainActor
final class StoryAmbientGunfireWorldBridge {
    private struct Active {
        let sessionID: StoryAmbientGunfireSessionID
        let eventID: StoryAmbientGunfireEventID
        let emitter: Entity
        let controller: AudioPlaybackController
        let continuation: CheckedContinuation<Void, Error>
    }

    private weak var sceneRoot: Entity?
    private var active: Active?

    var activeVoiceCount: Int { active == nil ? 0 : 1 }

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
        request: StoryAmbientGunfirePlaybackRequest
    ) async throws {
        guard active == nil else {
            throw StoryAmbientGunfireError.voiceLimitExceeded
        }
        guard let sceneRoot else {
            throw StoryAmbientGunfireError.sceneUnavailable
        }

        let emitter = Entity()
        emitter.name = "StoryAmbientGunfire_\(request.eventID.rawValue.uuidString)"
        emitter.position = sceneRoot.convert(position: request.worldPosition, from: nil)
        emitter.components.set(
            SpatialAudioComponent(
                gain: .zero,
                directLevel: .zero,
                reverbLevel: .zero,
                directivity: .beam(focus: .zero),
                distanceAttenuation: .rolloff(
                    factor: request.asset.distanceRolloffFactor
                )
            )
        )
        sceneRoot.addChild(emitter)

        let controller = emitter.prepareAudio(prepared.resource)
        controller.gain = request.asset.sourceGainDB

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
        sessionID: StoryAmbientGunfireSessionID,
        eventID: StoryAmbientGunfireEventID
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
        sessionID: StoryAmbientGunfireSessionID,
        eventID: StoryAmbientGunfireEventID,
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
            "[StoryAmbientGunfire] active event stopped " +
                "eventID=\(eventID.rawValue.uuidString) reason=\(reason)"
        )
    }
}
