import AVFoundation
import Foundation

actor StoryAftermathMusicActor {
    static let shared = StoryAftermathMusicActor()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var activeURL: URL?
    private var fadeTask: Task<Void, Never>?
    private var targetVolume: Float = 0
    private var memoryCueDucked = false

    func playLoop(
        fileURL: URL,
        targetDecibels: Float,
        fadeDuration: TimeInterval
    ) {
        let resolvedTargetVolume = Self.linearGain(decibels: targetDecibels)

        stop(reason: "replaceAftermathTrack")
        let item = AVPlayerItem(url: fileURL)
        item.audioMix = nil
        let queue = AVQueuePlayer()
        queue.volume = fadeDuration > 0 ? 0 : resolvedTargetVolume
        let loop = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        looper = loop
        activeURL = fileURL
        targetVolume = resolvedTargetVolume
        memoryCueDucked = false
        queue.play()

        if fadeDuration > 0 {
            fadeTask = Task { [weak self] in
                let frames = max(1, Int(ceil(fadeDuration * 30)))
                for frame in 1...frames {
                    guard !Task.isCancelled else { return }
                    let gain = resolvedTargetVolume * Float(frame) / Float(frames)
                    await self?.setVolume(gain)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }

        print("""
        [StoryAftermathMusic] playing
          file: \(fileURL.lastPathComponent)
          targetDecibels: \(targetDecibels)
          targetVolume: \(resolvedTargetVolume)
          audioMix: none
          battleRuntimeRetained: false
        """)
    }

    func isPlaying() -> Bool {
        player?.timeControlStatus == .playing
    }

    func duckForMemoryCue(
        fadeDuration: TimeInterval
    ) async -> Bool {
        guard player != nil else {
            return false
        }
        memoryCueDucked = true
        await fadeVolume(to: 0, duration: fadeDuration)
        guard memoryCueDucked else {
            return false
        }
        player?.pause()
        return true
    }

    func restoreAfterMemoryCue(
        fadeDuration: TimeInterval
    ) async {
        guard memoryCueDucked,
              player != nil else {
            return
        }
        memoryCueDucked = false
        player?.volume = 0
        player?.play()
        await fadeVolume(
            to: targetVolume,
            duration: fadeDuration
        )
    }

    func stop(reason: String) {
        fadeTask?.cancel()
        fadeTask = nil
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        activeURL = nil
        targetVolume = 0
        memoryCueDucked = false
        print("[StoryAftermathMusic] stopped reason=\(reason)")
    }

    private func setVolume(_ value: Float) {
        player?.volume = value
    }

    private func fadeVolume(
        to target: Float,
        duration: TimeInterval
    ) async {
        fadeTask?.cancel()
        fadeTask = nil
        guard duration > 0,
              let player else {
            self.player?.volume = target
            return
        }
        let start = player.volume
        let frames = max(1, Int(ceil(duration * 30)))
        for frame in 1...frames {
            guard Task.isCancelled == false else {
                return
            }
            let progress = Float(frame) / Float(frames)
            player.volume = start + ((target - start) * progress)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private nonisolated static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
