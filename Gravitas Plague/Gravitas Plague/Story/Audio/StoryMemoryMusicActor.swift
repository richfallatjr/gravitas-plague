import AVFoundation
import Foundation

actor StoryMemoryMusicActor {
    struct Token: Hashable, Sendable {
        let id: UUID
        let flowInstanceID: UUID
    }

    static let shared = StoryMemoryMusicActor()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var activeToken: Token?

    func start(
        descriptor: TuringFlowBackgroundMusicDescriptor,
        fileURL: URL,
        flowInstanceID: UUID
    ) async throws -> Token {
        await stopActive(reason: "replaced")

        let token = Token(
            id: UUID(),
            flowInstanceID: flowInstanceID
        )
        let item = AVPlayerItem(url: fileURL)
        let queue = AVQueuePlayer()
        let target = Self.linearGain(decibels: descriptor.gainDB)
        queue.volume = descriptor.fadeInSeconds > 0 ? 0 : target

        if descriptor.loops {
            looper = AVPlayerLooper(
                player: queue,
                templateItem: item
            )
        } else {
            queue.insert(item, after: nil)
        }

        player = queue
        activeToken = token
        queue.play()
        await fade(
            token: token,
            from: queue.volume,
            to: target,
            duration: descriptor.fadeInSeconds
        )

        print("""
        [StoryMemoryMusic] started
          flowInstanceID: \(flowInstanceID.uuidString)
          file: \(fileURL.lastPathComponent)
          gainDB: \(descriptor.gainDB)
          loops: \(descriptor.loops)
        """)
        return token
    }

    func stop(
        token: Token,
        fadeDuration: TimeInterval,
        reason: String
    ) async {
        guard activeToken == token else {
            return
        }
        await fade(
            token: token,
            from: player?.volume ?? 0,
            to: 0,
            duration: fadeDuration
        )
        guard activeToken == token else {
            return
        }
        releasePlayer()
        print("""
        [StoryMemoryMusic] stopped
          flowInstanceID: \(token.flowInstanceID.uuidString)
          reason: \(reason)
        """)
    }

    func stopAll(reason: String) async {
        await stopActive(reason: reason)
    }

    private func stopActive(reason: String) async {
        guard let token = activeToken else {
            return
        }
        await stop(
            token: token,
            fadeDuration: 0,
            reason: reason
        )
    }

    private func fade(
        token: Token,
        from start: Float,
        to target: Float,
        duration: TimeInterval
    ) async {
        guard duration > 0 else {
            player?.volume = target
            return
        }
        let frames = max(1, Int(ceil(duration * 30)))
        for frame in 1...frames {
            guard activeToken == token,
                  Task.isCancelled == false else {
                return
            }
            let progress = Float(frame) / Float(frames)
            player?.volume =
                start + ((target - start) * progress)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private func releasePlayer() {
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        activeToken = nil
    }

    private nonisolated static func linearGain(
        decibels: Float
    ) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
