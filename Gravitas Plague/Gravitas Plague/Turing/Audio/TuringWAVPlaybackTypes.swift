import AVFoundation
import Foundation

struct TuringGeneratedWAVSegment: Sendable, Hashable {
    let segmentIndex: Int
    let fileURL: URL
    let sampleRate: Double
    let channelCount: Int
    let frameCount: AVAudioFramePosition
    let durationSeconds: TimeInterval
}

enum TuringGeneratedWAVError: Error, LocalizedError {
    case emptySamples
    case nonFiniteSample(index: Int)
    case unsupportedChannelCount(Int)
    case invalidSampleCount(samples: Int, channels: Int)
    case invalidFormat
    case bufferAllocationFailed
    case missingRun
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySamples:
            return "Generated audio samples are empty."
        case .nonFiniteSample(let index):
            return "Generated audio contains NaN/Inf at sample index \(index)."
        case .unsupportedChannelCount(let count):
            return "Unsupported generated audio channel count: \(count)."
        case .invalidSampleCount(let samples, let channels):
            return "Generated sample count \(samples) is not divisible by channel count \(channels)."
        case .invalidFormat:
            return "Could not create generated WAV audio format."
        case .bufferAllocationFailed:
            return "Could not allocate generated WAV PCM buffer."
        case .missingRun:
            return "Generated WAV queue has no active run."
        case .playbackFailed(let detail):
            return "Generated WAV playback failed: \(detail)"
        }
    }
}
