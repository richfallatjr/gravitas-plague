import AVFoundation
import Foundation
import RealityKit

enum TuringWalkieAudioError: LocalizedError {
    case missingWalkieEmitter
    case missingAudioController
    case invalidGeneratedAudio(Int)
    case fileWriteFailed(String)

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
        }
    }
}

@MainActor
final class TuringWalkieSpatialPlaybackSink: TuringSpeechPlaybackSink {
    private enum Gain {
        static let turingPlaybackDB: Float = 0.0
    }

    private weak var audioController: GravitasDemoAudioController?
    private weak var walkieEmitter: Entity?
    private let transientRoot: URL
    private var activeRunRoot: URL?

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
        guard let audioController else {
            throw TuringWalkieAudioError.missingAudioController
        }
        guard let walkieEmitter,
              walkieEmitter.parent != nil else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        let fileURL = try writeGeneratedAudioFile(audio)
        let duration = Double(audio.samples.count) /
            max(1, audio.sampleRate * Double(audio.channelCount))

        _ = audioController.playGeneratedTuringAtWalkieSource(
            fileURL: fileURL,
            walkieEmitter: walkieEmitter,
            volumeDB: Gain.turingPlaybackDB,
            label: "turing_walkie_qwen.segment\(audio.segmentIndex)"
        )

        return duration
    }

    func playFillerClip(
        fileURL: URL,
        label: String
    ) async throws -> TimeInterval {
        guard let audioController else {
            throw TuringWalkieAudioError.missingAudioController
        }
        guard let walkieEmitter,
              walkieEmitter.parent != nil else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }

        _ = audioController.playGeneratedTuringAtWalkieSource(
            fileURL: fileURL,
            walkieEmitter: walkieEmitter,
            volumeDB: Gain.turingPlaybackDB,
            label: "turing_walkie_filler.\(label)"
        )

        return Self.durationSeconds(of: fileURL)
    }

    func stopAll(reason: String) async {
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
}

@MainActor
enum TuringStoryWalkieAudioRoute {
    private static var activeSink: TuringWalkieSpatialPlaybackSink?

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

        print("""
        [TuringAudio] walkie emitter selected
          emitter: \(walkieEmitter.name)
          source: turing_story_wall_bundle_v1
        """)
    }

    static func clear(reason: String) {
        if activeSink != nil {
            print("""
            [TuringAudio] walkie emitter cleared
              reason: \(reason)
            """)
        }
        activeSink = nil
    }

    static func makeActiveSink() -> TuringSpeechPlaybackSink? {
        activeSink
    }
}
