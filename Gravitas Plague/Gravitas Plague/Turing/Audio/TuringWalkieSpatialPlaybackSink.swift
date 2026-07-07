import AVFoundation
import Foundation
import RealityKit

enum TuringWalkieAudioError: LocalizedError {
    case missingWalkieEmitter
    case missingAudioController
    case invalidGeneratedAudio(Int)
    case fileWriteFailed(String)
    case playbackStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWalkieEmitter:
            return "Missing Turing walkie audio emitter."
        case .missingAudioController:
            return "Missing Gravitas audio controller for walkie playback."
        case .invalidGeneratedAudio(let segmentIndex):
            return "Invalid generated walkie audio for segment \(segmentIndex)."
        case .fileWriteFailed(let message):
            return "Failed to write walkie audio file: \(message)"
        case .playbackStartFailed(let label):
            return "Failed to start walkie playback: \(label)"
        }
    }
}

@MainActor
final class TuringWalkieSpatialPlaybackSink: TuringSpeechPlaybackSink {
    private enum Gain {
        static let turingPlaybackDB: Float = -6.0
    }

    private weak var audioController: GravitasDemoAudioController?
    private weak var walkieEmitter: Entity?
    private let transientRoot: URL
    private var activeRunRoot: URL?
    private var staticLoopController: AudioPlaybackController?
    private var generatedPlaybackIDsBySegment: [Int: UUID] = [:]
    private var generatedPlaybackEntitiesBySegment: [Int: Entity] = [:]
    private var generatedLane: Entity?
    private var fillerLane: Entity?
    private var staticLane: Entity?

    private let generatedPlaybackCompletionPollSeconds: TimeInterval = 0.05

    init(
        audioController: GravitasDemoAudioController,
        walkieEmitter: Entity,
        transientRoot: URL
    ) {
        self.audioController = audioController
        self.walkieEmitter = walkieEmitter
        self.transientRoot = transientRoot
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async {
        let sanitizedRunID = runID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let runRoot = transientRoot.appendingPathComponent(
            sanitizedRunID,
            isDirectory: true
        )
        activeRunRoot = runRoot
        generatedPlaybackIDsBySegment.removeAll(keepingCapacity: true)
        generatedPlaybackEntitiesBySegment.removeAll(keepingCapacity: true)
        do {
            try FileManager.default.createDirectory(
                at: runRoot,
                withIntermediateDirectories: true
            )
        } catch {
            print("""
            [TuringAudio] walkie transient directory failed
              path: \(runRoot.path)
              error: \(error.localizedDescription)
            """)
        }

        print("""
        [TuringAudio] walkie spatial sink installed
          emitter: \(walkieEmitter?.name ?? "nil")
          debugAudioRoutedToWalkie: true
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
        """)
    }

    func playGeneratedSegment(
        _ audio: TuringComputeGapGeneratedAudio
    ) async throws -> TimeInterval {
        print("""
        [TuringAudio] blocked legacy generated in-memory playback
          segmentIndex: \(audio.segmentIndex)
          requiredOwner: TuringSerialWAVFillerPlaybackQueue
          requiredMethod: qwenComputeFinished
        """)
        throw TuringWalkieAudioError.playbackStartFailed(
            "Legacy generated in-memory playback is disabled; use TuringSerialWAVFillerPlaybackQueue."
        )
    }

    func waitForGeneratedSegmentPlaybackCompletion(
        segmentIndex: Int,
        fallbackDuration: TimeInterval
    ) async {
        let started = Date()
        let maximumWait = max(0.25, fallbackDuration + 2.0)

        guard let playbackID = generatedPlaybackIDsBySegment[segmentIndex],
              let audioController else {
            try? await Task.sleep(
                nanoseconds: UInt64(
                    max(0.05, fallbackDuration)
                        * 1_000_000_000
                )
            )
            generatedPlaybackIDsBySegment.removeValue(forKey: segmentIndex)
            return
        }

        while Date().timeIntervalSince(started) < maximumWait {
            if audioController.isSpatialOneShotActive(id: playbackID) == false {
                break
            }
            try? await Task.sleep(
                nanoseconds: UInt64(
                    generatedPlaybackCompletionPollSeconds * 1_000_000_000
                )
            )
        }

        generatedPlaybackIDsBySegment.removeValue(forKey: segmentIndex)
        generatedPlaybackEntitiesBySegment.removeValue(forKey: segmentIndex)?
            .removeFromParent()

        print("""
        [TuringAudio] walkie generated playback completion observed
          segmentIndex: \(segmentIndex)
          fallbackDurationSeconds: \(String(format: "%.3f", fallbackDuration))
          waitedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(started)))
        """)
    }

    func playFillerClip(
        fileURL: URL,
        label: String
    ) async throws -> TimeInterval {
        guard let audioController else {
            throw TuringWalkieAudioError.missingAudioController
        }
        try ensureAudioLanes()
        guard let fillerLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        _ = audioController.playGeneratedTuringSpatialAudio(
            fileURL: fileURL,
            at: fillerLane,
            volumeDB: Gain.turingPlaybackDB,
            label: "turing_walkie_filler.\(label)"
        )

        print("""
        [TuringAudio] walkie filler playback lane started
          label: \(label)
          lane: TuringWalkieAudio_FillerLane
          rootEmitter: \(walkieEmitter?.name ?? "nil")
          isolatedLane: true
        """)

        return Self.durationSeconds(of: fileURL)
    }

    func startRadioStaticLoop(
        fileURL: URL,
        reason: String
    ) throws {
        guard staticLoopController == nil else {
            print("""
            [TuringRadioStaticLeadIn] already playing
              reason: \(reason)
              route: walkieSpatial
            """)
            return
        }

        guard let audioController else {
            throw TuringWalkieAudioError.missingAudioController
        }
        try ensureAudioLanes()
        guard let staticLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        audioController.prepareIfNeeded()

        let configuration = AudioFileResource.Configuration(
            loadingStrategy: .preload,
            shouldLoop: true
        )
        let resource = try AudioFileResource.load(
            contentsOf: fileURL,
            configuration: configuration
        )

        let controller = staticLane.playAudio(resource)
        controller.gain = Self.decibels(linearVolume: 0.20)
        staticLoopController = controller

        print("""
        [TuringRadioStaticLeadIn] started
          reason: \(reason)
          file: \(fileURL.lastPathComponent)
          route: walkieSpatial
          emitter: \(walkieEmitter?.name ?? "nil")
          lane: TuringWalkieAudio_StaticLane
        """)
    }

    func stopRadioStaticLoop(reason: String) {
        guard let staticLoopController else {
            return
        }

        staticLoopController.stop()
        self.staticLoopController = nil

        print("""
        [TuringRadioStaticLeadIn] stopped
          reason: \(reason)
          route: walkieSpatial
        """)
    }

    func stopAll(reason: String) async {
        stopRadioStaticLoop(reason: reason)
        generatedPlaybackIDsBySegment.removeAll(keepingCapacity: false)
        for entity in generatedPlaybackEntitiesBySegment.values {
            entity.removeFromParent()
        }
        generatedPlaybackEntitiesBySegment.removeAll(keepingCapacity: false)

        if let activeRunRoot,
           FileManager.default.fileExists(atPath: activeRunRoot.path) {
            do {
                try FileManager.default.removeItem(at: activeRunRoot)
            } catch {
                print("""
                [TuringAudio] walkie transient cleanup failed
                  reason: \(reason)
                  path: \(activeRunRoot.path)
                  error: \(error.localizedDescription)
                """)
            }
        }
        activeRunRoot = nil
    }

    private func ensureAudioLanes() throws {
        guard let walkieEmitter,
              walkieEmitter.parent != nil else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        if generatedLane?.parent == nil {
            generatedLane = Self.makeLane(
                named: "TuringWalkieAudio_GeneratedLane",
                under: walkieEmitter
            )
        }

        if fillerLane?.parent == nil {
            fillerLane = Self.makeLane(
                named: "TuringWalkieAudio_FillerLane",
                under: walkieEmitter
            )
        }

        if staticLane?.parent == nil {
            staticLane = Self.makeLane(
                named: "TuringWalkieAudio_StaticLane",
                under: walkieEmitter
            )
        }
    }

    private static func makeLane(
        named name: String,
        under root: Entity
    ) -> Entity {
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

    private func writeGeneratedAudioFile(
        _ audio: TuringComputeGapGeneratedAudio
    ) throws -> URL {
        guard audio.samples.isEmpty == false,
              audio.samples.allSatisfy({ $0.isFinite }) else {
            throw TuringWalkieAudioError.invalidGeneratedAudio(audio.segmentIndex)
        }

        let runRoot = activeRunRoot ?? transientRoot
        try FileManager.default.createDirectory(
            at: runRoot,
            withIntermediateDirectories: true
        )
        let fileName = String(
            format: "segment-%04d.wav",
            audio.segmentIndex
        )
        let fileURL = runRoot.appendingPathComponent(fileName)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: audio.channelCount,
            interleaved: false
        ) else {
            throw TuringWalkieAudioError.invalidGeneratedAudio(audio.segmentIndex)
        }

        let frameCount = AVAudioFrameCount(
            audio.samples.count / Int(audio.channelCount)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw TuringWalkieAudioError.invalidGeneratedAudio(audio.segmentIndex)
        }
        buffer.frameLength = frameCount

        if audio.channelCount == 1 {
            guard let channel = buffer.floatChannelData?[0] else {
                throw TuringWalkieAudioError.invalidGeneratedAudio(audio.segmentIndex)
            }
            audio.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base, count: audio.samples.count)
                }
            }
        } else {
            guard let channels = buffer.floatChannelData else {
                throw TuringWalkieAudioError.invalidGeneratedAudio(audio.segmentIndex)
            }
            let channelCount = Int(audio.channelCount)
            let frames = Int(frameCount)
            for channelIndex in 0..<channelCount {
                for frameIndex in 0..<frames {
                    channels[channelIndex][frameIndex] =
                        audio.samples[frameIndex * channelCount + channelIndex]
                }
            }
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        do {
            let audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            try audioFile.write(from: buffer)
            return fileURL
        } catch {
            throw TuringWalkieAudioError.fileWriteFailed(error.localizedDescription)
        }
    }

    private static func durationSeconds(of fileURL: URL) -> TimeInterval {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let sampleRate = file.fileFormat.sampleRate
            guard sampleRate > 0 else { return 0 }
            return Double(file.length) / sampleRate
        } catch {
            return 0
        }
    }

    private static func decibels(linearVolume: Float) -> Double {
        guard linearVolume > 0 else {
            return -96.0
        }

        return Double(20.0 * log10(linearVolume))
    }
}

@MainActor
enum TuringStoryWalkieAudioRoute {
    private static var activeSink: TuringWalkieSpatialPlaybackSink?
    private static var activeQueuedSink: TuringWalkieQueuedPlaybackSink?

    static func install(
        audioController: GravitasDemoAudioController,
        walkieEmitter: Entity
    ) {
        let transientRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TuringWalkieSpatialAudio",
                isDirectory: true
            )
        activeSink = TuringWalkieSpatialPlaybackSink(
            audioController: audioController,
            walkieEmitter: walkieEmitter,
            transientRoot: transientRoot
        )
        activeQueuedSink = TuringWalkieQueuedPlaybackSink(
            audioController: audioController,
            walkieEmitter: walkieEmitter,
            transientRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TuringWalkieQueuedAudio",
                    isDirectory: true
                )
        )

        print("""
        [TuringAudio] walkie emitter selected
          emitter: \(walkieEmitter.name)
          source: turing_story_wall_bundle_v1
        """)
    }

    static func clear(reason: String) {
        if activeSink != nil {
            activeSink?.stopRadioStaticLoop(reason: reason)

            print("""
            [TuringAudio] walkie emitter cleared
                reason: \(reason)
            """)
        }
        if let queuedSink = activeQueuedSink {
            Task { @MainActor in
                await queuedSink.cancelRun(reason: reason)
            }
        }
        activeSink = nil
        activeQueuedSink = nil
    }

    static func makeActiveSink() -> TuringSpeechPlaybackSink? {
        activeSink
    }

    static func makeActiveQueuedSink() -> TuringQueuedPlaybackSink? {
        activeQueuedSink
    }

    static func startActiveRadioStaticLoop(
        fileURL: URL,
        reason: String
    ) async -> Bool {
        guard let activeQueuedSink else {
            return false
        }

        do {
            try await activeQueuedSink.startStaticLoop(
                fileURL: fileURL,
                reason: reason
            )
            return true
        } catch {
            print("""
            [TuringRadioStaticLeadIn] walkie route failed
              reason: \(reason)
              route: walkieQueuedStaticLane
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    static func stopActiveRadioStaticLoop(reason: String) async {
        await activeQueuedSink?.stopStaticLoop(reason: reason)
    }
}
