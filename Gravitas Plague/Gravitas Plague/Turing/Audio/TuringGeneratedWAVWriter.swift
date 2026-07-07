import AVFoundation
import Foundation

final class TuringGeneratedWAVWriter: Sendable {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func prepareRunDirectory(runID: String) throws -> URL {
        let safeRunID = runID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let url = rootURL
            .appendingPathComponent(safeRunID, isDirectory: true)
            .appendingPathComponent("generated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func write(
        audio: TuringComputeGapGeneratedAudio,
        runDirectory: URL
    ) throws -> TuringGeneratedWAVSegment {
        guard audio.samples.isEmpty == false else {
            throw TuringGeneratedWAVError.emptySamples
        }
        for (index, sample) in audio.samples.enumerated()
            where sample.isFinite == false {
            throw TuringGeneratedWAVError.nonFiniteSample(index: index)
        }

        let channels = Int(audio.channelCount)
        guard channels == 1 || channels == 2 else {
            throw TuringGeneratedWAVError.unsupportedChannelCount(channels)
        }
        guard audio.samples.count % channels == 0 else {
            throw TuringGeneratedWAVError.invalidSampleCount(
                samples: audio.samples.count,
                channels: channels
            )
        }

        let frameCount = audio.samples.count / channels
        let finalURL = runDirectory.appendingPathComponent(
            String(format: "segment_%04d.wav", audio.segmentIndex)
        )
        let tmpURL = runDirectory.appendingPathComponent(
            String(format: "segment_%04d.tmp.wav", audio.segmentIndex)
        )
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try FileManager.default.removeItem(at: tmpURL)
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw TuringGeneratedWAVError.invalidFormat
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw TuringGeneratedWAVError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            throw TuringGeneratedWAVError.bufferAllocationFailed
        }

        if channels == 1 {
            for frame in 0..<frameCount {
                channelData[0][frame] = audio.samples[frame]
            }
        } else {
            for frame in 0..<frameCount {
                channelData[0][frame] = audio.samples[frame * 2]
                channelData[1][frame] = audio.samples[frame * 2 + 1]
            }
        }

        do {
            let file = try AVAudioFile(forWriting: tmpURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        try FileManager.default.moveItem(
            at: tmpURL,
            to: finalURL
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: finalURL.path
        )
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 44 else {
            throw TuringGeneratedWAVError.playbackFailed(
                "WAV validation found too-small file size: \(fileSize)"
            )
        }

        let validated = try AVAudioFile(forReading: finalURL)
        let duration = Double(validated.length) /
            validated.fileFormat.sampleRate
        guard validated.length > 0,
              duration > 0 else {
            throw TuringGeneratedWAVError.playbackFailed(
                "WAV validation produced zero duration"
            )
        }

        return TuringGeneratedWAVSegment(
            segmentIndex: audio.segmentIndex,
            fileURL: finalURL,
            sampleRate: validated.fileFormat.sampleRate,
            channelCount: Int(validated.fileFormat.channelCount),
            frameCount: validated.length,
            durationSeconds: duration
        )
    }
}
