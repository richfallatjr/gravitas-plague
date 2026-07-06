import AVFoundation
import Foundation
import RealityKit

@MainActor
final class TuringWalkieQueuedPlaybackSink: TuringQueuedPlaybackSink {
    private enum Gain {
        static let turingPlaybackDB: Float = -6.0
        static let staticLinearVolume: Float = 0.20
    }

    private weak var audioController: GravitasDemoAudioController?
    private weak var walkieEmitter: Entity?
    private let transientRoot: URL
    private var activeRunRoot: URL?
    private var staticLoopController: AudioPlaybackController?
    private var generatedLane: Entity?
    private var fillerLane: Entity?
    private var staticLane: Entity?
    private var transientEntitiesByHandleID: [UUID: Entity] = [:]

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
        transientEntitiesByHandleID.removeAll(keepingCapacity: true)

        do {
            try ensureAudioLanes()
            try FileManager.default.createDirectory(
                at: runRoot,
                withIntermediateDirectories: true
            )
        } catch {
            print("""
            [TuringQueuedAudio] walkie beginRun setup failed
              runID: \(runID)
              error: \(error.localizedDescription)
            """)
        }

        print("""
        [TuringQueuedAudio] walkie sink ready
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          emitter: \(walkieEmitter?.name ?? "nil")
          generatedLane: TuringWalkieAudio_GeneratedLane
          fillerLane: TuringWalkieAudio_FillerLane
          staticLane: TuringWalkieAudio_StaticLane
        """)
    }

    func playGeneratedSegment(
        _ audio: TuringComputeGapGeneratedAudio
    ) async throws -> TuringPlaybackHandle {
        guard let audioController else {
            throw TuringWalkieAudioError.missingAudioController
        }
        try ensureAudioLanes()
        guard let generatedLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        let fileURL = try writeGeneratedAudioFile(audio)
        let duration = Self.durationSeconds(of: fileURL)
        let segmentEntity = Entity()
        segmentEntity.name = String(
            format: "TuringWalkieAudio_Generated_%04d",
            audio.segmentIndex
        )
        segmentEntity.components.set(SpatialAudioComponent())
        generatedLane.addChild(segmentEntity)

        guard let playbackID = audioController.playGeneratedTuringSpatialAudio(
            fileURL: fileURL,
            at: segmentEntity,
            volumeDB: Gain.turingPlaybackDB,
            label: "turing_walkie_queue.generated.segment\(audio.segmentIndex)"
        ) else {
            segmentEntity.removeFromParent()
            throw TuringWalkieAudioError.playbackStartFailed(
                "turing_walkie_queue.generated.segment\(audio.segmentIndex)"
            )
        }

        transientEntitiesByHandleID[playbackID] = segmentEntity

        print("""
        [TuringQueuedAudio] generated segment started on walkie lane
          segmentIndex: \(audio.segmentIndex)
          handleID: \(playbackID.uuidString)
          lane: TuringWalkieAudio_GeneratedLane
          isolatedLane: true
          durationSeconds: \(String(format: "%.3f", duration))
        """)

        return TuringPlaybackHandle(
            id: playbackID,
            label: "generated.segment\(audio.segmentIndex)",
            duration: duration
        )
    }

    func playFillerClip(
        fileURL: URL,
        label: String
    ) async throws -> TuringPlaybackHandle {
        guard let audioController else {
            throw TuringWalkieAudioError.missingAudioController
        }
        try ensureAudioLanes()
        guard let fillerLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        guard let playbackID = audioController.playGeneratedTuringSpatialAudio(
            fileURL: fileURL,
            at: fillerLane,
            volumeDB: Gain.turingPlaybackDB,
            label: "turing_walkie_queue.filler.\(label)"
        ) else {
            throw TuringWalkieAudioError.playbackStartFailed(
                "turing_walkie_queue.filler.\(label)"
            )
        }

        let duration = Self.durationSeconds(of: fileURL)

        print("""
        [TuringQueuedAudio] filler clip started on walkie lane
          label: \(label)
          handleID: \(playbackID.uuidString)
          file: \(fileURL.lastPathComponent)
          lane: TuringWalkieAudio_FillerLane
          isolatedLane: true
          durationSeconds: \(String(format: "%.3f", duration))
        """)

        return TuringPlaybackHandle(
            id: playbackID,
            label: "filler.\(label)",
            duration: duration
        )
    }

    func waitForPlaybackCompletion(
        _ handle: TuringPlaybackHandle
    ) async {
        let started = Date()
        let maximumWait = max(0.25, handle.duration + 2.0)

        guard let audioController else {
            try? await Task.sleep(
                nanoseconds: UInt64(max(0.05, handle.duration) * 1_000_000_000)
            )
            cleanupTransientEntity(handleID: handle.id)
            return
        }

        while Date().timeIntervalSince(started) < maximumWait {
            if audioController.isSpatialOneShotActive(id: handle.id) == false {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        cleanupTransientEntity(handleID: handle.id)

        print("""
        [TuringQueuedAudio] playback completion observed
          label: \(handle.label)
          handleID: \(handle.id.uuidString)
          expectedDurationSeconds: \(String(format: "%.3f", handle.duration))
          waitedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(started)))
        """)
    }

    func startStaticLoop(
        fileURL: URL,
        reason: String
    ) async throws {
        guard staticLoopController == nil else {
            print("""
            [TuringQueuedAudio] static already playing
              reason: \(reason)
              lane: TuringWalkieAudio_StaticLane
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
        controller.gain = Self.decibels(linearVolume: Gain.staticLinearVolume)
        staticLoopController = controller

        print("""
        [TuringQueuedAudio] static loop started
          reason: \(reason)
          file: \(fileURL.lastPathComponent)
          lane: TuringWalkieAudio_StaticLane
          isolatedLane: true
        """)
    }

    func stopStaticLoop(reason: String) async {
        guard let staticLoopController else { return }
        staticLoopController.stop()
        self.staticLoopController = nil

        print("""
        [TuringQueuedAudio] static loop stopped
          reason: \(reason)
          lane: TuringWalkieAudio_StaticLane
        """)
    }

    func cancelRun(reason: String) async {
        await stopStaticLoop(reason: reason)
        for entity in transientEntitiesByHandleID.values {
            entity.removeFromParent()
        }
        transientEntitiesByHandleID.removeAll(keepingCapacity: false)

        if let activeRunRoot,
           FileManager.default.fileExists(atPath: activeRunRoot.path) {
            do {
                try FileManager.default.removeItem(at: activeRunRoot)
            } catch {
                print("""
                [TuringQueuedAudio] transient cleanup failed
                  reason: \(reason)
                  path: \(activeRunRoot.path)
                  error: \(error.localizedDescription)
                """)
            }
        }
        activeRunRoot = nil
    }

    private func cleanupTransientEntity(handleID: UUID) {
        transientEntitiesByHandleID.removeValue(forKey: handleID)?
            .removeFromParent()
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
        let fileName = String(format: "segment-%04d.wav", audio.segmentIndex)
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

        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try audioFile.write(from: buffer)
        return fileURL
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
        guard linearVolume > 0 else { return -96.0 }
        return Double(20.0 * log10(linearVolume))
    }
}
