import AVFoundation
import Foundation

actor Chapter02BattleMusicActor {
    static let shared = Chapter02BattleMusicActor()

    static let resourcePath =
        "Turing/Audio/chapter02/battle-03-music.mp3"
    static let targetGainDB: Float = 0
    static let postBattleGainDB = -Float.infinity
    static let postBattleFadeSeconds: TimeInterval = 1.5
    static let titleCardFadeSeconds: TimeInterval = 1.5
    static let interactionFadeSeconds: TimeInterval = 0.75

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var activeURL: URL?
    private var targetVolume: Float = 1
    private var desiredGainDB: Float = 0
    private var duckOwners = Set<String>()
    private var fadeGeneration = UUID()

    func startIfNeeded(reason: String) throws {
        try startIfNeeded(
            reason: reason,
            gainDB: Self.targetGainDB
        )
    }

    func startPostBattleIfNeeded(reason: String) throws {
        try startIfNeeded(
            reason: reason,
            gainDB: Self.postBattleGainDB
        )
    }

    func fadeToPostBattleLevel(reason: String) async {
        guard player != nil else { return }
        desiredGainDB = Self.postBattleGainDB
        targetVolume = Self.linearGain(decibels: desiredGainDB)
        guard duckOwners.isEmpty else { return }
        await fadeVolume(
            to: targetVolume,
            duration: Self.postBattleFadeSeconds
        )
        print("""
        [Chapter02BattleMusic] post-battle level reached
          gainDB: \(desiredGainDB)
          inaudible: true
          fadeSeconds: \(Self.postBattleFadeSeconds)
          reason: \(reason)
        """)
    }

    func fadeToFullLevelForTitleCard(
        reason: String,
        fadeDuration: TimeInterval =
            Chapter02BattleMusicActor.titleCardFadeSeconds
    ) async {
        guard let player else { return }
        desiredGainDB = Self.targetGainDB
        targetVolume = Self.linearGain(decibels: desiredGainDB)
        guard duckOwners.isEmpty else { return }
        player.play()
        await fadeVolume(to: targetVolume, duration: fadeDuration)
        print("""
        [Chapter02BattleMusic] title-card level reached
          gainDB: \(desiredGainDB)
          fadeSeconds: \(fadeDuration)
          reason: \(reason)
        """)
    }

    private func startIfNeeded(
        reason: String,
        gainDB: Float
    ) throws {
        let fileURL = try TuringResourceLoader.resourceURL(
            resourcePath: Self.resourcePath
        )

        if activeURL == fileURL, let player {
            desiredGainDB = gainDB
            targetVolume = Self.linearGain(decibels: gainDB)
            if duckOwners.isEmpty {
                player.volume = targetVolume
                player.play()
            }
            return
        }

        releasePlayer()
        let item = AVPlayerItem(url: fileURL)
        let queue = AVQueuePlayer()
        let loop = AVPlayerLooper(player: queue, templateItem: item)
        let resolvedVolume = Self.linearGain(decibels: gainDB)
        queue.volume = resolvedVolume
        player = queue
        looper = loop
        activeURL = fileURL
        targetVolume = resolvedVolume
        desiredGainDB = gainDB
        queue.play()

        print("""
        [Chapter02BattleMusic] started
          file: \(fileURL.lastPathComponent)
          gainDB: \(gainDB)
          loops: true
          reason: \(reason)
        """)
    }

    @discardableResult
    func duck(
        ownerID: String,
        fadeDuration: TimeInterval =
            Chapter02BattleMusicActor.interactionFadeSeconds
    ) async -> Bool {
        guard player != nil else { return false }
        let wasAudible = duckOwners.isEmpty
        duckOwners.insert(ownerID)
        guard wasAudible else { return true }

        await fadeVolume(to: 0, duration: fadeDuration)
        guard duckOwners.isEmpty == false else { return false }
        player?.pause()
        print("""
        [Chapter02BattleMusic] ducked
          ownerID: \(ownerID)
          fadeSeconds: \(fadeDuration)
          mediaPositionPreserved: true
        """)
        return true
    }

    func restore(
        ownerID: String,
        fadeDuration: TimeInterval =
            Chapter02BattleMusicActor.interactionFadeSeconds
    ) async {
        guard duckOwners.remove(ownerID) != nil,
              duckOwners.isEmpty,
              let player else {
            return
        }

        player.volume = 0
        player.play()
        await fadeVolume(to: targetVolume, duration: fadeDuration)
        print("""
        [Chapter02BattleMusic] restored
          ownerID: \(ownerID)
          gainDB: \(desiredGainDB)
          fadeSeconds: \(fadeDuration)
        """)
    }

    func hasActiveSession() -> Bool {
        player != nil
    }

    func stop(reason: String) {
        guard player != nil || looper != nil else { return }
        releasePlayer()
        print("[Chapter02BattleMusic] stopped reason=\(reason)")
    }

    private func fadeVolume(
        to target: Float,
        duration: TimeInterval
    ) async {
        let generation = UUID()
        fadeGeneration = generation
        guard duration > 0, let fadingPlayer = player else {
            player?.volume = target
            return
        }

        let start = fadingPlayer.volume
        let frames = max(1, Int(ceil(duration * 30)))
        for frame in 1...frames {
            guard fadeGeneration == generation,
                  player === fadingPlayer,
                  Task.isCancelled == false else {
                return
            }
            let progress = Float(frame) / Float(frames)
            fadingPlayer.volume = start + ((target - start) * progress)
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private func releasePlayer() {
        fadeGeneration = UUID()
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        activeURL = nil
        targetVolume = 1
        desiredGainDB = Self.targetGainDB
        duckOwners.removeAll(keepingCapacity: false)
    }

    private nonisolated static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}

nonisolated enum Chapter02BattleMusicInteractionPolicy {
    static func ducksConversation(conversationKey: String) -> Bool {
        conversationKey ==
            TuringStorySurfaceFlowBinding.chapter02CrankGravitasPSA
                .conversationKey
    }
}
