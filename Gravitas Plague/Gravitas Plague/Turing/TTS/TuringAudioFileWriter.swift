import AVFoundation
import Foundation

struct TuringAudioCacheFile: Sendable, Hashable {
    let fileURL: URL
    let metadataURL: URL
    let durationSeconds: TimeInterval
    let sampleRate: Int
    let channelCount: Int
}

actor TuringAudioFileWriter {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func write(
        waveform: QwenWaveform,
        cacheKey: String
    ) throws -> TuringAudioCacheFile {
        guard !waveform.samples.isEmpty else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Qwen returned an empty waveform."
            )
        }
        guard waveform.channelCount == 1 else {
            throw TuringRuntimeError.qwenSynthesisFailed(
                "Phase 0 expects mono Qwen output, got \(waveform.channelCount) channels."
            )
        }

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let wavURL = rootURL.appendingPathComponent("\(cacheKey).wav")
        let metadataURL = rootURL.appendingPathComponent("\(cacheKey).json")
        let frameCount = AVAudioFrameCount(waveform.samples.count)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(waveform.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw TuringRuntimeError.audioCacheFailed(
                "Failed to allocate AVAudioPCMBuffer."
            )
        }

        buffer.frameLength = frameCount
        waveform.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress,
               let channel = buffer.floatChannelData?[0] {
                channel.update(from: base, count: waveform.samples.count)
            }
        }

        let audioFile = try AVAudioFile(
            forWriting: wavURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try audioFile.write(from: buffer)

        let duration = Double(waveform.samples.count) / Double(waveform.sampleRate)
        let metadata = TuringAudioFileMetadata(
            schemaVersion: 1,
            fileName: wavURL.lastPathComponent,
            durationSeconds: duration,
            sampleRate: waveform.sampleRate,
            channelCount: waveform.channelCount,
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: metadataURL,
            options: [.atomic]
        )

        return TuringAudioCacheFile(
            fileURL: wavURL,
            metadataURL: metadataURL,
            durationSeconds: duration,
            sampleRate: waveform.sampleRate,
            channelCount: waveform.channelCount
        )
    }
}

struct TuringAudioFileMetadata: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let fileName: String
    let durationSeconds: TimeInterval
    let sampleRate: Int
    let channelCount: Int
    let createdAt: Date
}
