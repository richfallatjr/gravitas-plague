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
    ) async throws -> TuringAudioCacheFile {
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
        let tempURL = rootURL.appendingPathComponent("\(cacheKey).tmp.wav")
        let metadataURL = rootURL.appendingPathComponent("\(cacheKey).json")
        let sanitized = waveform.samples.map { sample -> Float in
            guard sample.isFinite else {
                return 0
            }

            return max(-1, min(1, sample))
        }
        let frameCount = AVAudioFrameCount(sanitized.count)

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
        sanitized.withUnsafeBufferPointer { source in
            if let base = source.baseAddress,
               let channel = buffer.floatChannelData?[0] {
                channel.update(from: base, count: sanitized.count)
            }
        }

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        let audioFile = try AVAudioFile(
            forWriting: tempURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try audioFile.write(from: buffer)

        if FileManager.default.fileExists(atPath: wavURL.path) {
            try FileManager.default.removeItem(at: wavURL)
        }
        try FileManager.default.moveItem(
            at: tempURL,
            to: wavURL
        )

        let duration = Double(sanitized.count) / Double(waveform.sampleRate)
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

    func removeTemporaryFile(
        forCacheKey cacheKey: String
    ) async throws {
        let tempURL = rootURL.appendingPathComponent("\(cacheKey).tmp.wav")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
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
