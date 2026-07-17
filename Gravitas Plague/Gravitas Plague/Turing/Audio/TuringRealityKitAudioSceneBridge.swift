import Foundation
import RealityKit

@MainActor
final class TuringRealityKitAudioSceneBridge {
    private struct Active {
        let handle: TuringAudioPlaybackHandle
        let entity: Entity
        let controller: AudioPlaybackController
    }

    private weak var emitter: Entity?
    private var lanes: [TuringAudioClipKind: Entity] = [:]
    private var activeByID: [UUID: Active] = [:]
    private let completionSink: @Sendable (
        TuringAudioPlaybackHandle,
        Bool
    ) -> Void

    init(
        emitter: Entity,
        completionSink: @escaping @Sendable (
            TuringAudioPlaybackHandle,
            Bool
        ) -> Void
    ) {
        self.emitter = emitter
        self.completionSink = completionSink
    }

    func replaceEmitter(_ emitter: Entity) {
        stopAll(reason: "replaceEmitter")
        lanes.values.forEach { $0.removeFromParent() }
        lanes.removeAll(keepingCapacity: false)
        self.emitter = emitter
    }

    func start(
        prepared: TuringPreparedRealityAudioResource,
        request: TuringAudioPlaybackRequest
    ) throws -> TuringAudioPlaybackHandle {
        let startedAt = ContinuousClock.now
        guard let emitter, emitter.parent != nil else {
            throw TuringRuntimeError.invalidConfig(
                "Missing installed emitter for \(request.route.rawValue)."
            )
        }
        let lane = laneEntity(for: request.kind, emitter: emitter)
        let child = Entity()
        child.name = "TuringAudio_\(request.kind.rawValue)_\(request.requestID.uuidString)"
        child.components.set(SpatialAudioComponent())
        lane.addChild(child)

        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: request.requestID,
            runID: request.runID,
            route: request.route
        )
        let controller = child.playAudio(prepared.resource)
        controller.gain = Double(request.gainDB)
        activeByID[handle.id] = Active(
            handle: handle,
            entity: child,
            controller: controller
        )
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.complete(handle: handle, successfully: true)
            }
        }
        TuringAudioOffloadSignposts.sceneBridgeDuration(
            operation: "start",
            startedAt: startedAt
        )
        return handle
    }

    func stop(_ handle: TuringAudioPlaybackHandle) {
        guard let active = activeByID.removeValue(forKey: handle.id),
              active.handle == handle else {
            return
        }
        active.controller.completionHandler = nil
        active.controller.stop()
        active.entity.removeFromParent()
    }

    func stopAll(reason: String) {
        let values = Array(activeByID.values)
        activeByID.removeAll(keepingCapacity: false)
        for active in values {
            active.controller.completionHandler = nil
            active.controller.stop()
            active.entity.removeFromParent()
        }
        print("[TuringAudioOffload] scene bridge stopped all reason=\(reason)")
    }

    private func complete(
        handle: TuringAudioPlaybackHandle,
        successfully: Bool
    ) {
        guard let active = activeByID.removeValue(forKey: handle.id),
              active.handle == handle else {
            return
        }
        active.controller.completionHandler = nil
        active.entity.removeFromParent()
        completionSink(handle, successfully)
    }

    private func laneEntity(
        for kind: TuringAudioClipKind,
        emitter: Entity
    ) -> Entity {
        if let existing = lanes[kind] {
            return existing
        }
        let lane = Entity()
        lane.name = "TuringAudio_\(kind.rawValue)_Lane"
        lane.position = .zero
        lane.components.set(SpatialAudioComponent())
        emitter.addChild(lane)
        lanes[kind] = lane
        return lane
    }
}
