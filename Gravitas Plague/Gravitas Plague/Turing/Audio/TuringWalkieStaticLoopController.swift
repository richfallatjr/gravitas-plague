import AVFoundation
import Foundation
import RealityKit

@MainActor
final class TuringWalkieStaticLoopController {
    private enum Gain {
        static let staticLinearVolume: Float = 0.20
    }

    private weak var walkieEmitter: Entity?
    private var staticLane: Entity?
    private var staticLoopController: AudioPlaybackController?

    init(walkieEmitter: Entity) {
        self.walkieEmitter = walkieEmitter
    }

    func startStaticLoop(fileURL: URL, reason: String) throws {
        guard staticLoopController == nil else {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
              spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
            """)
            return
        }

        try ensureStaticLane()
        guard let staticLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        let resource = try AudioFileResource.load(
            contentsOf: fileURL,
            configuration: AudioFileResource.Configuration(
                loadingStrategy: .preload,
                shouldLoop: true
            )
        )
        let controller = staticLane.playAudio(resource)
        controller.gain = Self.decibels(linearVolume: Gain.staticLinearVolume)
        staticLoopController = controller

        print("""
        [TuringRadioStaticLeadIn] started
          reason: \(reason)
          file: \(fileURL.lastPathComponent)
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
          lane: TuringWalkieAudio_StaticLane
        """)
    }

    func stopStaticLoop(reason: String) {
        guard let staticLoopController else {
            return
        }
        staticLoopController.stop()
        self.staticLoopController = nil
        print("""
        [TuringRadioStaticLeadIn] stopped
          reason: \(reason)
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
        """)
    }

    private func ensureStaticLane() throws {
        guard let walkieEmitter,
              walkieEmitter.parent != nil else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        if staticLane?.parent == nil {
            if let existing = walkieEmitter.children.first(
                where: { $0.name == "TuringWalkieAudio_StaticLane" }
            ) {
                existing.components.set(SpatialAudioComponent())
                staticLane = existing
            } else {
                let lane = Entity()
                lane.name = "TuringWalkieAudio_StaticLane"
                lane.position = .zero
                lane.components.set(SpatialAudioComponent())
                walkieEmitter.addChild(lane)
                staticLane = lane
            }
        }
    }

    private static func decibels(linearVolume: Float) -> Double {
        guard linearVolume > 0 else { return -96.0 }
        return Double(20.0 * log10(linearVolume))
    }
}

@MainActor
enum TuringStoryWalkieAudioRoute {
    private static var clipPlayer: TuringWalkieOneShotClipPlayer?
    private static var staticController: TuringWalkieStaticLoopController?

    static func install(
        audioController: GravitasDemoAudioController,
        walkieEmitter: Entity
    ) {
        _ = audioController
        clipPlayer = TuringWalkieOneShotClipPlayer(walkieEmitter: walkieEmitter)
        staticController = TuringWalkieStaticLoopController(
            walkieEmitter: walkieEmitter
        )

        print("""
        [TuringAudio] walkie emitter selected
          emitter: \(walkieEmitter.name)
          requiredEmitter: TuringStoryWalkieTalkie_AudioEmitter
          source: turing_story_wall_bundle_v1
        """)
    }

    static func clear(reason: String) {
        clipPlayer?.cancelAll(reason: reason)
        staticController?.stopStaticLoop(reason: reason)
        clipPlayer = nil
        staticController = nil
        print("""
        [TuringAudio] walkie emitter cleared
          reason: \(reason)
        """)
    }

    static func makeActiveClipPlayer() -> TuringWalkieOneShotClipPlayer? {
        clipPlayer
    }

    static func startActiveRadioStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        guard let staticController else {
            return false
        }

        do {
            try staticController.startStaticLoop(fileURL: fileURL, reason: reason)
            return true
        } catch {
            print("""
            [TuringRadioStaticLeadIn] walkie route failed
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    static func stopActiveRadioStaticLoop(reason: String) async {
        staticController?.stopStaticLoop(reason: reason)
    }
}
