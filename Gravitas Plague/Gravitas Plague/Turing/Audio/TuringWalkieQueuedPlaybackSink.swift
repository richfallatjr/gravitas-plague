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
    private var activePlaybackControllersByHandleID: [UUID: AudioPlaybackController] = [:]
    private var completedPlaybackHandleIDs = Set<UUID>()
    private var playbackCompletionContinuationsByHandleID: [UUID: [CheckedContinuation<Void, Never>]] = [:]

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
        for controller in activePlaybackControllersByHandleID.values {
            controller.stop()
        }
        activePlaybackControllersByHandleID.removeAll(keepingCapacity: true)
        for continuations in playbackCompletionContinuationsByHandleID.values {
            for continuation in continuations {
                continuation.resume()
            }
        }
        playbackCompletionContinuationsByHandleID.removeAll(keepingCapacity: true)
        completedPlaybackHandleIDs.removeAll(keepingCapacity: true)
        for entity in transientEntitiesByHandleID.values {
            entity.removeFromParent()
        }
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
        print("""
        [TuringQueuedAudio] blocked legacy generated in-memory playback
          segmentIndex: \(audio.segmentIndex)
          requiredOwner: TuringGeneratedWAVPlaybackQueue
          requiredMethod: playGeneratedWAVSegment
        """)
        throw TuringWalkieAudioError.playbackStartFailed(
            "Legacy generated in-memory playback is disabled; use TuringGeneratedWAVPlaybackQueue."
        )
    }

    func playGeneratedWAVSegment(
        _ wav: TuringGeneratedWAVSegment
    ) async throws -> TuringPlaybackHandle {
        try ensureAudioLanes()
        guard let generatedLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        let segmentEntity = Entity()
        segmentEntity.name = String(
            format: "TuringWalkieAudio_GeneratedWAV_%04d",
            wav.segmentIndex
        )
        segmentEntity.components.set(SpatialAudioComponent())
        generatedLane.addChild(segmentEntity)

        let resource = try loadOneShotResource(wav.fileURL)
        let controller = segmentEntity.playAudio(resource)
        controller.gain = Double(Gain.turingPlaybackDB)
        let playbackID = UUID()
        activePlaybackControllersByHandleID[playbackID] = controller
        transientEntitiesByHandleID[playbackID] = segmentEntity
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.markPlaybackCompleted(
                    handleID: playbackID,
                    label: "generatedWAV.segment\(wav.segmentIndex)"
                )
            }
        }

        print("""
        [TuringQueuedAudio] generated wav started on walkie lane
          segmentIndex: \(wav.segmentIndex)
          handleID: \(playbackID.uuidString)
          file: \(wav.fileURL.lastPathComponent)
          lane: TuringWalkieAudio_GeneratedLane
          rootEmitter: \(walkieEmitter?.name ?? "nil")
          isolatedLane: true
          sinkOwnedController: true
          completionSource: AudioPlaybackController.completionHandler
          durationSeconds: \(String(format: "%.3f", wav.durationSeconds))
        """)

        return TuringPlaybackHandle(
            id: playbackID,
            label: "generatedWAV.segment\(wav.segmentIndex)",
            duration: wav.durationSeconds
        )
    }

    func playFillerClip(
        fileURL: URL,
        label: String
    ) async throws -> TuringPlaybackHandle {
        try ensureAudioLanes()
        guard let fillerLane else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        let duration = Self.durationSeconds(of: fileURL)
        let fillerEntity = Entity()
        fillerEntity.name = "TuringWalkieAudio_Filler_\(label)"
        fillerEntity.components.set(SpatialAudioComponent())
        fillerLane.addChild(fillerEntity)

        let resource = try loadOneShotResource(fileURL)
        let controller = fillerEntity.playAudio(resource)
        controller.gain = Double(Gain.turingPlaybackDB)
        let playbackID = UUID()
        activePlaybackControllersByHandleID[playbackID] = controller
        transientEntitiesByHandleID[playbackID] = fillerEntity
        controller.completionHandler = { [weak self] in
            Task { @MainActor in
                self?.markPlaybackCompleted(
                    handleID: playbackID,
                    label: "filler.\(label)"
                )
            }
        }

        print("""
        [TuringQueuedAudio] filler clip started on walkie lane
          label: \(label)
          handleID: \(playbackID.uuidString)
          file: \(fileURL.lastPathComponent)
          lane: TuringWalkieAudio_FillerLane
          isolatedLane: true
          sinkOwnedController: true
          completionSource: AudioPlaybackController.completionHandler
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

        if completedPlaybackHandleIDs.remove(handle.id) != nil {
            print("""
            [TuringQueuedAudio] playback completion observed
              label: \(handle.label)
              handleID: \(handle.id.uuidString)
              expectedDurationSeconds: \(String(format: "%.3f", handle.duration))
              completionSource: AudioPlaybackController.completionHandler
              waitedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(started)))
              controllerRetainedUntilRunCleanup: true
              entityRetainedUntilRunCleanup: true
            """)
            return
        }

        await withCheckedContinuation { continuation in
            playbackCompletionContinuationsByHandleID[
                handle.id,
                default: []
            ].append(continuation)
        }

        print("""
        [TuringQueuedAudio] playback completion observed
          label: \(handle.label)
          handleID: \(handle.id.uuidString)
          expectedDurationSeconds: \(String(format: "%.3f", handle.duration))
          completionSource: AudioPlaybackController.completionHandler
          waitedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(started)))
          controllerRetainedUntilRunCleanup: true
          entityRetainedUntilRunCleanup: true
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
        for continuations in playbackCompletionContinuationsByHandleID.values {
            for continuation in continuations {
                continuation.resume()
            }
        }
        playbackCompletionContinuationsByHandleID.removeAll(keepingCapacity: false)
        completedPlaybackHandleIDs.removeAll(keepingCapacity: false)
        for controller in activePlaybackControllersByHandleID.values {
            controller.stop()
        }
        activePlaybackControllersByHandleID.removeAll(keepingCapacity: false)
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

    private func markPlaybackCompleted(
        handleID: UUID,
        label: String
    ) {
        if let continuations = playbackCompletionContinuationsByHandleID
            .removeValue(forKey: handleID) {
            for continuation in continuations {
                continuation.resume()
            }
        } else {
            completedPlaybackHandleIDs.insert(handleID)
        }

        print("""
        [TuringQueuedAudio] playback controller completed
          label: \(label)
          handleID: \(handleID.uuidString)
          completionSource: AudioPlaybackController.completionHandler
        """)
    }

    private func loadOneShotResource(
        _ fileURL: URL
    ) throws -> AudioFileResource {
        let configuration = AudioFileResource.Configuration(
            loadingStrategy: .preload,
            shouldLoop: false
        )
        return try AudioFileResource.load(
            contentsOf: fileURL,
            configuration: configuration
        )
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
