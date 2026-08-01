import AVFoundation
import Foundation

actor PlagueMainMenuMusicActor {
    static let shared = PlagueMainMenuMusicActor()
    static let resourcePath =
        "Turing/Audio/menu/main-menu-song-01.mp3"

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var activeURL: URL?

    func startIfNeeded(reason: String) throws {
        if let player {
            player.play()
            print("[PlagueMenuMusic] retained reason=\(reason)")
            return
        }

        let url = try TuringResourceLoader.resourceURL(
            resourcePath: Self.resourcePath
        )
        let queue = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        let loop = AVPlayerLooper(
            player: queue,
            templateItem: item
        )

        queue.volume = 1
        player = queue
        looper = loop
        activeURL = url
        queue.play()

        print("""
        [PlagueMenuMusic] started
          file: \(url.lastPathComponent)
          loops: true
          gainDB: 0
          reason: \(reason)
        """)
    }

    func stop(reason: String) {
        guard player != nil else {
            return
        }

        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        activeURL = nil

        print("[PlagueMenuMusic] stopped reason=\(reason)")
    }

    func isPlaying() -> Bool {
        player?.timeControlStatus == .playing
    }

    func activeFileName() -> String? {
        activeURL?.lastPathComponent
    }
}
