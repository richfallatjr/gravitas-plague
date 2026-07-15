import Foundation
import RealityKit

@MainActor
final class TuringRollingBenchRadioController {
    enum State: String, Sendable, Equatable {
        case unavailable
        case stopped
        case playing
    }

    private(set) var state: State = .unavailable
    var onStateChanged: (@MainActor (State) -> Void)?

    private weak var emitter: Entity?
    private var staticLane: Entity?
    private var cueLane: Entity?
    private var broadcastLane: Entity?

    private var staticResource: AudioFileResource?
    private var cueResource: AudioFileResource?
    private var broadcastResource: AudioFileResource?

    private var staticController: AudioPlaybackController?
    private var cueController: AudioPlaybackController?
    private var broadcastController: AudioPlaybackController?
    private var repeatDelayTask: Task<Void, Never>?
    private var cycleID = UUID()

    func prepareResources() async throws {
        let staticURL = try requireResource(
            name: "Narrow-band-analog",
            extension: "wav"
        )
        let cueURL = try requireResource(
            name: "Create_a_short_emerg_beeping",
            extension: "wav"
        )
        let broadcastURL = try requireResource(
            name: "EmergencyBroadcast",
            extension: "mp3"
        )

        staticResource = try loadResource(url: staticURL, loops: true)
        cueResource = try loadResource(url: cueURL, loops: false)
        broadcastResource = try loadResource(url: broadcastURL, loops: false)

        for url in [staticURL, cueURL, broadcastURL] {
            print(
                "[TuringRollingBenchRadio] asset ready file=\(url.lastPathComponent)"
            )
        }
        transition(to: .stopped, reason: "resourcesReady")
    }

    func install(emitter: Entity) {
        stopActiveCycle(reason: "install")
        removeLanes()
        self.emitter = emitter
        staticLane = makeSpatialLane(
            name: TuringRollingBenchEntityName.runtimeStaticLane,
            parent: emitter
        )
        cueLane = makeSpatialLane(
            name: TuringRollingBenchEntityName.runtimeCueLane,
            parent: emitter
        )
        broadcastLane = makeSpatialLane(
            name: TuringRollingBenchEntityName.runtimeBroadcastLane,
            parent: emitter
        )
        transition(
            to: resourcesAreReady ? .stopped : .unavailable,
            reason: resourcesAreReady ? "installed" : "installedWithoutResources"
        )
    }

    func toggle(source: String) {
        switch state {
        case .unavailable:
            print(
                "[TuringRollingBenchRadio] toggle ignored state=unavailable source=\(source)"
            )
        case .stopped:
            play(source: source)
        case .playing:
            pause(source: source)
        }
    }

    func play(source: String) {
        guard state == .stopped,
              let staticLane,
              let staticResource,
              cueLane != nil,
              cueResource != nil,
              broadcastLane != nil,
              broadcastResource != nil else {
            return
        }

        stopActiveCycle(reason: "newPlay")
        cycleID = UUID()
        let activeCycleID = cycleID

        let staticPlayback = staticLane.playAudio(staticResource)
        staticPlayback.gain = TuringRollingBenchTuning.staticGainDB
        staticController = staticPlayback
        transition(to: .playing, reason: "play.\(source)")
        startCue(cycleID: activeCycleID)

        print(
            """
            [TuringRollingBenchRadio] static started
              cycleID: \(activeCycleID.uuidString)
              file: Narrow-band-analog.wav
              loops: true
              gainDB: \(String(format: "%.2f", TuringRollingBenchTuning.staticGainDB))
              emitter: \(TuringRollingBenchEntityName.runtimeAudioEmitter)
              spatial: true
            """
        )
    }

    func pause(source: String) {
        guard state == .playing else { return }
        stopActiveCycle(reason: "pause.\(source)")
        transition(to: .stopped, reason: "pause.\(source)")
    }

    func reset(reason: String) {
        stopActiveCycle(reason: "reset.\(reason)")
        removeLanes()
        emitter = nil
        transition(
            to: resourcesAreReady ? .stopped : .unavailable,
            reason: "reset.\(reason)"
        )
        print("[TuringRollingBenchRadio] reset reason=\(reason)")
    }

    func unload(reason: String) {
        reset(reason: reason)
        staticResource = nil
        cueResource = nil
        broadcastResource = nil
        transition(to: .unavailable, reason: "unload.\(reason)")
    }

    private var resourcesAreReady: Bool {
        staticResource != nil && cueResource != nil && broadcastResource != nil
    }

    private func startCue(cycleID: UUID) {
        guard state == .playing,
              self.cycleID == cycleID,
              let cueLane,
              let cueResource else {
            return
        }

        cueController?.completionHandler = nil
        cueController?.stop()
        let controller = cueLane.playAudio(cueResource)
        controller.gain = TuringRollingBenchTuning.cueGainDB
        cueController = controller
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.cueDidComplete(cycleID: cycleID)
            }
        }

        print(
            """
            [TuringRollingBenchRadio] emergency beep started
              cycleID: \(cycleID.uuidString)
              file: Create_a_short_emerg_beeping.wav
              gainDB: \(String(format: "%.1f", TuringRollingBenchTuning.cueGainDB))
              completionSource: AudioPlaybackController.completionHandler
              spatial: true
            """
        )
    }

    private func cueDidComplete(cycleID: UUID) {
        guard state == .playing, self.cycleID == cycleID else {
            logStaleCompletion(kind: "emergencyBeep", cycleID: cycleID)
            return
        }
        cueController = nil
        print(
            "[TuringRollingBenchRadio] emergency beep completed cycleID=\(cycleID.uuidString) action=startBroadcast"
        )
        startBroadcast(cycleID: cycleID)
    }

    private func startBroadcast(cycleID: UUID) {
        guard state == .playing,
              self.cycleID == cycleID,
              let broadcastLane,
              let broadcastResource else {
            return
        }

        broadcastController?.completionHandler = nil
        broadcastController?.stop()
        let controller = broadcastLane.playAudio(broadcastResource)
        controller.gain = TuringRollingBenchTuning.broadcastGainDB
        broadcastController = controller
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.broadcastDidComplete(cycleID: cycleID)
            }
        }

        print(
            """
            [TuringRollingBenchRadio] broadcast started
              cycleID: \(cycleID.uuidString)
              file: EmergencyBroadcast.mp3
              gainDB: \(String(format: "%.2f", TuringRollingBenchTuning.broadcastGainDB))
              completionSource: AudioPlaybackController.completionHandler
              emitter: \(TuringRollingBenchEntityName.runtimeAudioEmitter)
              spatial: true
            """
        )
    }

    private func broadcastDidComplete(cycleID: UUID) {
        guard state == .playing, self.cycleID == cycleID else {
            logStaleCompletion(kind: "broadcast", cycleID: cycleID)
            return
        }
        broadcastController = nil
        print(
            """
            [TuringRollingBenchRadio] broadcast completed
              cycleID: \(cycleID.uuidString)
              completionSource: AudioPlaybackController.completionHandler
              staticContinues: true
              repeatPauseSeconds: 30
              nextAction: emergencyBeep
            """
        )

        repeatDelayTask?.cancel()
        repeatDelayTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TuringRollingBenchTuning.broadcastRepeatDelay
                )
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.state == .playing,
                  self.cycleID == cycleID else {
                return
            }
            self.repeatDelayTask = nil
            print(
                "[TuringRollingBenchRadio] repeat pause completed cycleID=\(cycleID.uuidString) action=startEmergencyBeep"
            )
            self.startCue(cycleID: cycleID)
        }
    }

    private func stopActiveCycle(reason: String) {
        cycleID = UUID()
        repeatDelayTask?.cancel()
        repeatDelayTask = nil
        cueController?.completionHandler = nil
        broadcastController?.completionHandler = nil
        cueController?.stop()
        broadcastController?.stop()
        staticController?.stop()
        cueController = nil
        broadcastController = nil
        staticController = nil
        print("[TuringRollingBenchRadio] active cycle stopped reason=\(reason)")
    }

    private func removeLanes() {
        staticLane?.removeFromParent()
        cueLane?.removeFromParent()
        broadcastLane?.removeFromParent()
        staticLane = nil
        cueLane = nil
        broadcastLane = nil
    }

    private func makeSpatialLane(name: String, parent: Entity) -> Entity {
        let lane = Entity()
        lane.name = name
        lane.position = .zero
        lane.components.set(SpatialAudioComponent())
        parent.addChild(lane)
        return lane
    }

    private func requireResource(
        name: String,
        extension fileExtension: String
    ) throws -> URL {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Turing/Audio/rolling-bench"
        ) ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
        guard let url else {
            throw TuringRuntimeError.invalidConfig(
                "Missing rolling-bench radio asset: \(name).\(fileExtension)"
            )
        }
        return url
    }

    private func loadResource(url: URL, loops: Bool) throws -> AudioFileResource {
        try AudioFileResource.load(
            contentsOf: url,
            configuration: .init(
                loadingStrategy: .preload,
                shouldLoop: loops
            )
        )
    }

    private func logStaleCompletion(kind: String, cycleID: UUID) {
        print(
            "[TuringRollingBenchRadio] stale completion ignored kind=\(kind) cycleID=\(cycleID.uuidString) activeCycleID=\(self.cycleID.uuidString)"
        )
    }

    private func transition(to next: State, reason: String) {
        guard state != next else { return }
        let previous = state
        state = next
        onStateChanged?(next)
        print(
            "[TuringRollingBenchRadio] state changed from=\(previous.rawValue) to=\(next.rawValue) reason=\(reason)"
        )
    }
}
