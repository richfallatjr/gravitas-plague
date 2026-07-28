import AVFoundation
import Foundation

@MainActor
final class Battle01RichPrerecordingController: NSObject, Battle01RichPrerecordingPlaying, AVAudioPlayerDelegate {
    private static let richGainDecibels: Float = -5

    enum PlaybackError: LocalizedError {
        case playbackDidNotStart
        case interrupted(String)

        var errorDescription: String? {
            switch self {
            case .playbackDidNotStart:
                return "Battle01 Rich prerecording did not start."
            case .interrupted(let reason):
                return "Battle01 Rich prerecording interrupted: \(reason)"
            }
        }
    }

    private var activePlayer: AVAudioPlayer?
    private var activeBattleInstanceID: UUID?
    private var completion: CheckedContinuation<Void, Error>?

    func play(
        descriptor: TuringPrerecordingDescriptor,
        fileURL: URL,
        battleInstanceID: UUID
    ) async throws {
        guard activePlayer == nil else { return }

        try await withTaskCancellationHandler(operation: {
            try await awaitPlayback(
                descriptor: descriptor,
                fileURL: fileURL,
                battleInstanceID: battleInstanceID
            )
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(reason: "taskCancelled")
            }
        })
    }

    private func awaitPlayback(
        descriptor: TuringPrerecordingDescriptor,
        fileURL: URL,
        battleInstanceID: UUID
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            do {
                let player = try AVAudioPlayer(contentsOf: fileURL)
                player.delegate = self
                player.numberOfLoops = 0
                player.volume = min(
                    1,
                    max(0, powf(10, Self.richGainDecibels / 20))
                )
                player.prepareToPlay()
                guard player.play() else {
                    continuation.resume(throwing: PlaybackError.playbackDidNotStart)
                    return
                }
                activePlayer = player
                activeBattleInstanceID = battleInstanceID
                completion = continuation
                print("""
                [Battle01] Rich PR started
                  battleInstanceID: \(battleInstanceID.uuidString)
                  prerecordingID: \(descriptor.prerecordingID)
                  file: \(fileURL.lastPathComponent)
                  route: global
                  gainDecibels: \(Self.richGainDecibels)
                  generatedTTS: false
                """)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel(reason: String) {
        activePlayer?.stop()
        activePlayer = nil
        activeBattleInstanceID = nil
        let pending = completion
        completion = nil
        pending?.resume(throwing: PlaybackError.interrupted(reason))
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
            print("[Battle01] Rich PR decode error error=\(message)")
            self?.finish(player: player, successfully: false)
        }
    }

    private func finish(player: AVAudioPlayer, successfully: Bool) {
        guard activePlayer === player else { return }
        activePlayer = nil
        activeBattleInstanceID = nil
        let pending = completion
        completion = nil
        if successfully {
            pending?.resume()
            print("[Battle01] Rich PR completed")
        } else {
            pending?.resume(throwing: PlaybackError.interrupted("delegateUnsuccessful"))
        }
    }
}
