import AVFoundation
import Foundation

actor StoryAftermathMusicActor {
    static let shared = StoryAftermathMusicActor()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var activeURL: URL?
    private var fadeTask: Task<Void, Never>?

    func playLoop(
        fileURL: URL,
        targetDecibels: Float,
        fadeDuration: TimeInterval
    ) {
        let targetVolume = Self.linearGain(decibels: targetDecibels)

        stop(reason: "replaceAftermathTrack")
        let item = AVPlayerItem(url: fileURL)
        item.audioMix = nil
        let queue = AVQueuePlayer()
        queue.volume = fadeDuration > 0 ? 0 : targetVolume
        let loop = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        looper = loop
        activeURL = fileURL
        queue.play()

        if fadeDuration > 0 {
            fadeTask = Task { [weak self] in
                let frames = max(1, Int(ceil(fadeDuration * 30)))
                for frame in 1...frames {
                    guard !Task.isCancelled else { return }
                    let gain = targetVolume * Float(frame) / Float(frames)
                    await self?.setVolume(gain)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }

        print("""
        [StoryAftermathMusic] playing
          file: \(fileURL.lastPathComponent)
          targetDecibels: \(targetDecibels)
          targetVolume: \(targetVolume)
          audioMix: none
          battleRuntimeRetained: false
        """)
    }

    func isPlaying() -> Bool {
        player?.timeControlStatus == .playing
    }

    func stop(reason: String) {
        fadeTask?.cancel()
        fadeTask = nil
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        activeURL = nil
        print("[StoryAftermathMusic] stopped reason=\(reason)")
    }

    private func setVolume(_ value: Float) {
        player?.volume = value
    }

    private nonisolated static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
