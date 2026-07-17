import AVFoundation
import Foundation

actor TuringGeneratedPlaybackFileStore {
    struct PreparedClip: Sendable, Equatable {
        let runID: String
        let segmentIndex: Int
        let fileURL: URL
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
    }

    private let rootURL: URL
    private var directoriesByRunID: [String: URL] = [:]

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func beginRun(_ runID: String) throws -> URL {
        TuringAudioOffloadSignposts.assertNotMainThread("beginRun")
        let safe = runID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = rootURL.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        directoriesByRunID[runID] = directory
        return directory
    }

    func write(
        runID: String,
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) throws -> PreparedClip {
        TuringAudioOffloadSignposts.assertNotMainThread("writeGeneratedWAV")
        TuringAudioOffloadSignposts.offMain(
            "writeGeneratedWAV",
            file: String(format: "segment_%04d.wav", segmentIndex)
        )
        guard let directory = directoriesByRunID[runID] else {
            throw TuringRuntimeError.invalidConfig(
                "No generated-audio directory for run \(runID)."
            )
        }
        guard audio.samples.isEmpty == false,
              audio.sampleRate > 0,
              audio.channelCount > 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Generated segment \(segmentIndex) has invalid audio metadata."
            )
        }

        let channelCount = audio.channelCount
        let channelCountInt = Int(channelCount)
        let totalFrames = audio.samples.count / channelCountInt
        guard totalFrames > 0,
              totalFrames * channelCountInt == audio.samples.count else {
            throw TuringRuntimeError.invalidConfig(
                "Generated segment \(segmentIndex) sample count is not divisible by channel count."
            )
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: channelCount,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ), let channelData = buffer.floatChannelData else {
            throw TuringRuntimeError.invalidConfig(
                "Could not allocate generated-audio buffer."
            )
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        for frame in 0..<totalFrames {
            for channel in 0..<channelCountInt {
                let value = audio.samples[frame * channelCountInt + channel]
                channelData[channel][frame] = value.isFinite
                    ? max(-1, min(1, value))
                    : 0
            }
        }

        let stem = String(format: "segment_%04d", segmentIndex)
        let temporaryURL = directory.appendingPathComponent("\(stem).tmp.wav")
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: finalURL)

        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

        let validation = try AVAudioFile(forReading: finalURL)
        guard validation.length > 0,
              validation.fileFormat.sampleRate == audio.sampleRate,
              validation.fileFormat.channelCount == channelCount else {
            try? FileManager.default.removeItem(at: finalURL)
            throw TuringRuntimeError.invalidConfig(
                "Generated WAV validation failed for segment \(segmentIndex)."
            )
        }
        return PreparedClip(
            runID: runID,
            segmentIndex: segmentIndex,
            fileURL: finalURL,
            frameCount: validation.length,
            sampleRate: validation.fileFormat.sampleRate,
            channelCount: validation.fileFormat.channelCount
        )
    }

    func delete(_ clip: PreparedClip, reason: String) {
        TuringAudioOffloadSignposts.assertNotMainThread("deleteGeneratedWAV")
        try? FileManager.default.removeItem(at: clip.fileURL)
        print("""
        [TuringAudioOffload] generated file deleted
          runID: \(clip.runID)
          segmentIndex: \(clip.segmentIndex)
          reason: \(reason)
        """)
    }

    func delete(
        fileURL: URL,
        runID: String,
        segmentIndex: Int,
        reason: String
    ) {
        TuringAudioOffloadSignposts.assertNotMainThread("deleteGeneratedWAV")
        try? FileManager.default.removeItem(at: fileURL)
        print("""
        [TuringAudioOffload] generated file deleted
          runID: \(runID)
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
    }

    func endRun(_ runID: String, reason: String) {
        TuringAudioOffloadSignposts.assertNotMainThread("endRun")
        guard let directory = directoriesByRunID.removeValue(forKey: runID) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
        print("""
        [TuringAudioOffload] generated run removed
          runID: \(runID)
          reason: \(reason)
        """)
    }
}
