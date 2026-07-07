import AVFoundation
import Foundation
import RealityKit

enum TuringWalkieAudioError: LocalizedError {
    case missingWalkieEmitter
    case playbackStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWalkieEmitter:
            return "Missing Turing walkie audio emitter."
        case .playbackStartFailed(let label):
            return "Failed to start walkie playback: \(label)"
        }
    }
}

@MainActor
final class TuringWalkieOneShotClipPlayer {
    enum ClipKind: String {
        case generated
        case filler

        var laneName: String {
            switch self {
            case .generated:
                return "TuringWalkieAudio_GeneratedLane"
            case .filler:
                return "TuringWalkieAudio_FillerLane"
            }
        }
    }

    private enum Gain {
        static let playbackDB: Double = -6.0
    }

    private weak var walkieEmitter: Entity?
    private var controllersByHandleID: [UUID: AudioPlaybackController] = [:]
    private var entitiesByHandleID: [UUID: Entity] = [:]
    private var generatedLane: Entity?
    private var fillerLane: Entity?

    init(walkieEmitter: Entity) {
        self.walkieEmitter = walkieEmitter
    }

    @discardableResult
    func playOneShot(
        fileURL: URL,
        kind: ClipKind,
        label: String,
        completion: @escaping @MainActor (UUID) -> Void
    ) throws -> UUID {
        try ensureLanes()
        let lane: Entity?
        switch kind {
        case .generated:
            lane = generatedLane
        case .filler:
            lane = fillerLane
        }

        guard let lane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        let handleID = UUID()
        let entity = Entity()
        entity.name = "TuringWalkieAudio_\(kind.rawValue)_\(label)"
        entity.components.set(SpatialAudioComponent())
        lane.addChild(entity)

        let resource = try AudioFileResource.load(
            contentsOf: fileURL,
            configuration: AudioFileResource.Configuration(
                loadingStrategy: .preload,
                shouldLoop: false
            )
        )
        let controller = entity.playAudio(resource)
        controller.gain = Gain.playbackDB
        controllersByHandleID[handleID] = controller
        entitiesByHandleID[handleID] = entity
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.complete(handleID: handleID, completion: completion)
            }
        }

        print("""
        [TuringPlaybackRebuild] walkie one-shot started
          kind: \(kind.rawValue)
          label: \(label)
          handleID: \(handleID.uuidString)
          file: \(fileURL.lastPathComponent)
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
          lane: \(kind.laneName)
          completionSource: AudioPlaybackController.completionHandler
        """)

        return handleID
    }

    func cancel(handleID: UUID, reason: String) {
        controllersByHandleID.removeValue(forKey: handleID)?.stop()
        entitiesByHandleID.removeValue(forKey: handleID)?.removeFromParent()
        print("""
        [TuringPlaybackRebuild] one-shot cancelled
          handleID: \(handleID.uuidString)
          reason: \(reason)
        """)
    }

    func cancelAll(reason: String) {
        for controller in controllersByHandleID.values {
            controller.stop()
        }
        for entity in entitiesByHandleID.values {
            entity.removeFromParent()
        }
        controllersByHandleID.removeAll(keepingCapacity: false)
        entitiesByHandleID.removeAll(keepingCapacity: false)
        print("""
        [TuringPlaybackRebuild] one-shot player cleared
          reason: \(reason)
        """)
    }

    private func complete(
        handleID: UUID,
        completion: @escaping @MainActor (UUID) -> Void
    ) {
        controllersByHandleID.removeValue(forKey: handleID)
        entitiesByHandleID.removeValue(forKey: handleID)?.removeFromParent()
        completion(handleID)
    }

    private func ensureLanes() throws {
        guard let walkieEmitter,
              walkieEmitter.parent != nil else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        if generatedLane?.parent == nil {
            generatedLane = Self.makeLane(
                named: ClipKind.generated.laneName,
                under: walkieEmitter
            )
        }

        if fillerLane?.parent == nil {
            fillerLane = Self.makeLane(
                named: ClipKind.filler.laneName,
                under: walkieEmitter
            )
        }
    }

    private static func makeLane(named name: String, under root: Entity) -> Entity {
        if let existing = root.children.first(where: { $0.name == name }) {
            existing.components.set(SpatialAudioComponent())
            return existing
        }

        let lane = Entity()
        lane.name = name
        lane.position = .zero
        lane.components.set(SpatialAudioComponent())
        root.addChild(lane)
        return lane
    }
}
