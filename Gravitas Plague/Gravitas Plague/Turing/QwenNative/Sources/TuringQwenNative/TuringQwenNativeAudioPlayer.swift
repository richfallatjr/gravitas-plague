import AVFoundation
import Foundation

@MainActor
private final class TuringQwenNativeRetainedPlayback: NSObject {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var continuation: CheckedContinuation<Void, Error>?

    func play(samples: [Float], sampleRate: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            do {
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(sampleRate),
                    channels: 1,
                    interleaved: false
                ) else {
                    throw TuringQwenNativeError.emptyAudio
                }

                let frameCount = AVAudioFrameCount(samples.count)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCount
                ) else {
                    throw TuringQwenNativeError.emptyAudio
                }

                buffer.frameLength = frameCount
                let channel = buffer.floatChannelData![0]
                for index in samples.indices {
                    let sample = samples[index]
                    channel[index] = sample.isFinite ? max(-1, min(1, sample)) : 0
                }

                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                try engine.start()

                self.engine = engine
                self.player = player

                player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                    Task { @MainActor in
                        self?.player?.stop()
                        self?.engine?.stop()
                        self?.player = nil
                        self?.engine = nil
                        self?.continuation?.resume()
                        self?.continuation = nil
                    }
                }

                player.play()
            } catch {
                continuation.resume(throwing: error)
                self.continuation = nil
            }
        }
    }
}

public enum TuringQwenNativeMemoryPlayer {
    @MainActor
    private static var retained: TuringQwenNativeRetainedPlayback?

    public static var shared: TuringQwenNativeMemoryPlayer.Type {
        TuringQwenNativeMemoryPlayer.self
    }

    public static func play(samples: [Float], sampleRate: Int) async throws {
        guard samples.isEmpty == false else {
            throw TuringQwenNativeError.emptyAudio
        }

        await MainActor.run {
            retained = TuringQwenNativeRetainedPlayback()
        }
        try await retained!.play(samples: samples, sampleRate: sampleRate)
        await MainActor.run {
            retained = nil
        }
    }
}
