import AVFoundation
import Foundation
import RealityKit

@MainActor
final class TuringWalkieStaticLoopController {
    private enum Gain {
        static let ambientStaticDB: Double = -23.0
        static let sendingStaticDB: Double = -16.5
    }

    private weak var walkieEmitter: Entity?
    private var loopControllersByLaneName: [String: AudioPlaybackController] = [:]

    init(walkieEmitter: Entity) {
        self.walkieEmitter = walkieEmitter
    }

    func startStaticLoop(fileURL: URL, reason: String) throws {
        try startAmbientWalkieStaticLoopSync(fileURL: fileURL, reason: reason)
    }

    func stopStaticLoop(reason: String) {
        stopAmbientWalkieStaticLoopSync(reason: reason)
    }

    func startAmbientWalkieStaticLoop(
        fileURL: URL,
        reason: String
    ) async throws {
        try startAmbientWalkieStaticLoopSync(fileURL: fileURL, reason: reason)
    }

    func stopAmbientWalkieStaticLoop(reason: String) async {
        stopAmbientWalkieStaticLoopSync(reason: reason)
    }

    func startSendingStaticLoop(
        fileURL: URL,
        reason: String
    ) async throws {
        try startLoop(
            fileURL: fileURL,
            reason: reason,
            laneName: "TuringWalkieAudio_SendingStaticLane",
            logName: "sending walkie static",
            gainDB: Gain.sendingStaticDB
        )
    }

    func stopSendingStaticLoop(reason: String) async {
        stopLoop(
            laneName: "TuringWalkieAudio_SendingStaticLane",
            reason: reason,
            logName: "sending walkie static"
        )
    }

    func stopAllStaticLoops(reason: String) {
        stopLoop(
            laneName: "TuringWalkieAudio_StaticLane",
            reason: reason,
            logName: "ambient walkie static"
        )
        stopLoop(
            laneName: "TuringWalkieAudio_SendingStaticLane",
            reason: reason,
            logName: "sending walkie static"
        )
    }

    private func startAmbientWalkieStaticLoopSync(
        fileURL: URL,
        reason: String
    ) throws {
        try startLoop(
            fileURL: fileURL,
            reason: reason,
            laneName: "TuringWalkieAudio_StaticLane",
            logName: "ambient walkie static",
            gainDB: Gain.ambientStaticDB
        )
    }

    private func stopAmbientWalkieStaticLoopSync(reason: String) {
        stopLoop(
            laneName: "TuringWalkieAudio_StaticLane",
            reason: reason,
            logName: "ambient walkie static"
        )
    }

    private func startLoop(
        fileURL: URL,
        reason: String,
        laneName: String,
        logName: String,
        gainDB: Double
    ) throws {
        guard loopControllersByLaneName[laneName] == nil else {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
              staticKind: \(logName)
              spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
              lane: \(laneName)
            """)
            return
        }

        let lane = try ensureLane(named: laneName)
        let resource = try AudioFileResource.load(
            contentsOf: fileURL,
            configuration: AudioFileResource.Configuration(
                loadingStrategy: .preload,
                shouldLoop: true
            )
        )
        let controller = lane.playAudio(resource)
        controller.gain = gainDB
        loopControllersByLaneName[laneName] = controller
        TuringAudioSessionCoordinator.shared.beginPlayback(
            owner: "TuringWalkieStaticLoopController.\(laneName)"
        )

        print("""
        [TuringRadioStaticLeadIn] started
          reason: \(reason)
          staticKind: \(logName)
          file: \(fileURL.lastPathComponent)
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
          lane: \(laneName)
          gainDB: \(String(format: "%.1f", gainDB))
        """)
    }

    private func stopLoop(
        laneName: String,
        reason: String,
        logName: String
    ) {
        guard let controller = loopControllersByLaneName
            .removeValue(forKey: laneName) else {
            return
        }

        controller.stop()
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringWalkieStaticLoopController.\(laneName)"
        )
        print("""
        [TuringRadioStaticLeadIn] stopped
          reason: \(reason)
          staticKind: \(logName)
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
          lane: \(laneName)
        """)
    }

    private func ensureLane(named laneName: String) throws -> Entity {
        guard let walkieEmitter,
              walkieEmitter.parent != nil else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        if let existing = walkieEmitter.children.first(
            where: { $0.name == laneName }
        ) {
            existing.components.set(SpatialAudioComponent())
            return existing
        }

        let lane = Entity()
        lane.name = laneName
        lane.position = .zero
        lane.components.set(SpatialAudioComponent())
        walkieEmitter.addChild(lane)
        return lane
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
        staticController?.stopAllStaticLoops(reason: reason)
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
        await startAmbientWalkieStaticLoop(fileURL: fileURL, reason: reason)
    }

    static func startAmbientWalkieStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        guard let staticController else {
            return false
        }

        do {
            try await staticController.startAmbientWalkieStaticLoop(
                fileURL: fileURL,
                reason: reason
            )
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
        await stopAmbientWalkieStaticLoop(reason: reason)
    }

    static func stopAmbientWalkieStaticLoop(reason: String) async {
        await staticController?.stopAmbientWalkieStaticLoop(reason: reason)
    }

    static func startSendingStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        guard let staticController else {
            return false
        }

        do {
            try await staticController.startSendingStaticLoop(
                fileURL: fileURL,
                reason: reason
            )
            return true
        } catch {
            print("""
            [TuringWalkieComms] sending static route failed
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    static func stopSendingStaticLoop(reason: String) async {
        await staticController?.stopSendingStaticLoop(reason: reason)
    }
}
