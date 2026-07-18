import AVFoundation
import Foundation

@MainActor
final class Battle01SoundtrackController: NSObject, Battle01SoundtrackControlling, AVAudioPlayerDelegate {
    enum SoundtrackError: LocalizedError {
        case notPrepared
        case playbackDidNotStart

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "Battle01 soundtrack was not prepared."
            case .playbackDidNotStart:
                return "Battle01 soundtrack AVAudioPlayer.play() returned false."
            }
        }
    }

    private var preparedURL: URL?
    private var preparedAftermathURL: URL?
    private var activePlayer: AVAudioPlayer?
    private var activeBattleInstanceID: UUID?
    private var onCompleted: (@MainActor (UUID, Bool) -> Void)?

    var isPlaying: Bool {
        activePlayer?.isPlaying == true
    }

    func prepare(fileURL: URL) throws {
        let validator = try AVAudioPlayer(contentsOf: fileURL)
        guard validator.duration > 0 else {
            throw SoundtrackError.notPrepared
        }
        preparedURL = fileURL
        print("[Battle01] soundtrack prepared durationSeconds=\(validator.duration)")
    }

    func prepareAftermathLoop(fileURL: URL) throws {
        let validator = try AVAudioPlayer(contentsOf: fileURL)
        guard validator.duration > 0 else {
            throw SoundtrackError.notPrepared
        }
        preparedAftermathURL = fileURL
        print("[Battle01] aftermath soundtrack prepared durationSeconds=\(validator.duration)")
    }

    func playOnce(
        battleInstanceID: UUID,
        onStarted: @escaping @MainActor (UUID) -> Void,
        onCompleted: @escaping @MainActor (UUID, Bool) -> Void
    ) throws {
        guard activePlayer == nil else { return }
        guard let preparedURL else { throw SoundtrackError.notPrepared }

        let player = try AVAudioPlayer(contentsOf: preparedURL)
        player.delegate = self
        player.numberOfLoops = 0
        player.prepareToPlay()
        guard player.play() else {
            throw SoundtrackError.playbackDidNotStart
        }

        activePlayer = player
        activeBattleInstanceID = battleInstanceID
        self.onCompleted = onCompleted
        onStarted(battleInstanceID)
    }

    func transferToAftermathLoop(
        battleInstanceID: UUID,
        targetDecibels: Float,
        fadeDurationSeconds: TimeInterval,
        onStarted: @escaping @MainActor (UUID) -> Void
    ) async throws {
        guard let preparedAftermathURL else { throw SoundtrackError.notPrepared }

        let outgoing = activePlayer
        let fadeDuration = max(0, fadeDurationSeconds)
        let targetGain = Self.linearGain(decibels: targetDecibels)
        outgoing?.setVolume(0, fadeDuration: fadeDuration)
        await StoryAftermathMusicActor.shared.playLoop(
            fileURL: preparedAftermathURL,
            targetVolume: targetGain,
            fadeDuration: fadeDuration
        )
        onStarted(battleInstanceID)

        if fadeDuration > 0 {
            try await Task.sleep(for: .seconds(fadeDuration))
        }
        outgoing?.stop()
        activePlayer = nil
        activeBattleInstanceID = nil
        onCompleted = nil
        preparedURL = nil
        self.preparedAftermathURL = nil

        print("""
        [Battle01] aftermath ownership transferred
          file: \(preparedAftermathURL.lastPathComponent)
          targetDecibels: \(targetDecibels)
          targetLinearGain: \(targetGain)
          fadeDurationSeconds: \(fadeDuration)
          loopsUntilPrologueTeardown: true
          attackTrackReleased: true
          battleCallbacksReleased: true
          owner: StoryAftermathMusicActor
        """)
    }

    func stop(reason: String) {
        activePlayer?.stop()
        activePlayer = nil
        activeBattleInstanceID = nil
        onCompleted = nil
        preparedURL = nil
        preparedAftermathURL = nil
        print("[Battle01] soundtrack stopped reason=\(reason)")
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.finish(player: player, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? "unknown decode error"
        Task { @MainActor [weak self] in
            print("[Battle01] soundtrack decode error error=\(message)")
            self?.finish(player: player, successfully: false)
        }
    }

    private func finish(player: AVAudioPlayer, successfully: Bool) {
        guard activePlayer === player,
              let instanceID = activeBattleInstanceID else { return }
        let completion = onCompleted
        activePlayer = nil
        activeBattleInstanceID = nil
        onCompleted = nil
        completion?(instanceID, successfully)
    }

    nonisolated static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
