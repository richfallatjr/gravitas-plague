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
    private var activePlayer: AVAudioPlayer?
    private var activeBattleInstanceID: UUID?
    private var onCompleted: (@MainActor (UUID, Bool) -> Void)?

    func prepare(fileURL: URL) throws {
        let validator = try AVAudioPlayer(contentsOf: fileURL)
        guard validator.duration > 0 else {
            throw SoundtrackError.notPrepared
        }
        preparedURL = fileURL
        print("[Battle01] soundtrack prepared durationSeconds=\(validator.duration)")
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

    func stop(reason: String) {
        activePlayer?.stop()
        activePlayer = nil
        activeBattleInstanceID = nil
        onCompleted = nil
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
}
