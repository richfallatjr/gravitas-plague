import AVFoundation
import Foundation

struct Chapter01DadBattleMusicEpoch: Hashable, Sendable {
    let battleInstanceID: UUID
    let playbackID: UUID
}

@MainActor
final class Chapter01DadBattleMusicController: NSObject, AVAudioPlayerDelegate {
    enum MusicError: LocalizedError {
        case notPrepared
        case playbackDidNotStart
        case staleEpoch

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "The Dad battle soundtrack is not prepared."
            case .playbackDidNotStart:
                return "The Dad battle soundtrack did not start."
            case .staleEpoch:
                return "The Dad battle soundtrack epoch is stale."
            }
        }
    }

    private struct Boundary {
        let seconds: TimeInterval
        let callback: @MainActor (Chapter01DadBattleMusicEpoch) -> Void
    }

    private var preparedURL: URL?
    private var preparedGainDB: Float = 0
    private var preparedDuration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var activeEpoch: Chapter01DadBattleMusicEpoch?
    private var terminalMediaTime: TimeInterval?
    private var boundaries: [String: Boundary] = [:]
    private var firedBoundaryIDs = Set<String>()

    var isPlaying: Bool { player?.isPlaying == true }

    func prepare(fileURL: URL, gainDB: Float) throws {
        let validator = try AVAudioPlayer(contentsOf: fileURL)
        guard validator.duration > 0 else { throw MusicError.notPrepared }
        preparedURL = fileURL
        preparedGainDB = gainDB
        preparedDuration = validator.duration
        print(
            "[Chapter01DadBattle] music prepared file=\(fileURL.lastPathComponent) " +
                "duration=\(validator.duration) gainDB=\(gainDB)"
        )
    }

    func playOnce(
        battleInstanceID: UUID
    ) throws -> Chapter01DadBattleMusicEpoch {
        guard player == nil, let preparedURL else {
            throw MusicError.notPrepared
        }
        let nextPlayer = try AVAudioPlayer(contentsOf: preparedURL)
        nextPlayer.delegate = self
        nextPlayer.numberOfLoops = 0
        nextPlayer.volume = Self.linearGain(decibels: preparedGainDB)
        nextPlayer.prepareToPlay()
        guard nextPlayer.play() else { throw MusicError.playbackDidNotStart }

        let epoch = Chapter01DadBattleMusicEpoch(
            battleInstanceID: battleInstanceID,
            playbackID: UUID()
        )
        player = nextPlayer
        activeEpoch = epoch
        terminalMediaTime = nil
        boundaries.removeAll(keepingCapacity: false)
        firedBoundaryIDs.removeAll(keepingCapacity: false)
        print(
            "[Chapter01DadBattle] music actual start " +
                "battleInstanceID=\(battleInstanceID.uuidString) " +
                "playbackID=\(epoch.playbackID.uuidString) mediaTime=0"
        )
        return epoch
    }

    func installMediaTimeBoundary(
        at seconds: TimeInterval,
        epoch: Chapter01DadBattleMusicEpoch,
        boundaryID: String,
        onReached: @escaping @MainActor (Chapter01DadBattleMusicEpoch) -> Void
    ) throws {
        guard epoch == activeEpoch, seconds >= 0 else {
            throw MusicError.staleEpoch
        }
        boundaries[boundaryID] = Boundary(
            seconds: seconds,
            callback: onReached
        )
        print(
            "[Chapter01DadBattle] media boundary installed " +
                "boundaryID=\(boundaryID) mediaTime=\(seconds) " +
                "playbackID=\(epoch.playbackID.uuidString)"
        )
        reconcileBoundaries()
    }

    func update() {
        reconcileBoundaries()
    }

    func mediaTimeSeconds(
        for epoch: Chapter01DadBattleMusicEpoch
    ) -> TimeInterval? {
        guard epoch == activeEpoch else { return nil }
        if let player { return player.currentTime }
        return terminalMediaTime
    }

    func hasFiredBoundary(
        _ boundaryID: String,
        epoch: Chapter01DadBattleMusicEpoch
    ) -> Bool {
        epoch == activeEpoch && firedBoundaryIDs.contains(boundaryID)
    }

    func stop(
        epoch: Chapter01DadBattleMusicEpoch?,
        reason: String
    ) {
        if let epoch, epoch != activeEpoch { return }
        player?.stop()
        player = nil
        activeEpoch = nil
        terminalMediaTime = nil
        boundaries.removeAll(keepingCapacity: false)
        firedBoundaryIDs.removeAll(keepingCapacity: false)
        preparedURL = nil
        preparedDuration = 0
        print("[Chapter01DadBattle] music stopped reason=\(reason)")
    }

    func fadeOutAndStop(
        epoch: Chapter01DadBattleMusicEpoch,
        durationSeconds: TimeInterval,
        reason: String
    ) async throws {
        guard epoch == activeEpoch else { throw MusicError.staleEpoch }
        let fadeDuration = max(0, durationSeconds)

        if let fadingPlayer = player, fadingPlayer.isPlaying {
            print(
                "[Chapter01DadBattle] music fade started " +
                    "playbackID=\(epoch.playbackID.uuidString) " +
                    "durationSeconds=\(fadeDuration)"
            )
            fadingPlayer.setVolume(0, fadeDuration: fadeDuration)
            if fadeDuration > 0 {
                try await Task.sleep(for: .seconds(fadeDuration))
            }
            try Task.checkCancellation()
            guard epoch == activeEpoch else { throw MusicError.staleEpoch }
        }

        stop(epoch: epoch, reason: reason)
        print(
            "[Chapter01DadBattle] music fade completed " +
                "playbackID=\(epoch.playbackID.uuidString)"
        )
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
        Task { @MainActor [weak self] in
            print(
                "[Chapter01DadBattle] music decode error " +
                    "error=\(error?.localizedDescription ?? "unknown")"
            )
            self?.finish(player: player, successfully: false)
        }
    }

    private func reconcileBoundaries() {
        guard let epoch = activeEpoch,
              let mediaTime = mediaTimeSeconds(for: epoch) else { return }
        let ready = boundaries
            .filter { !firedBoundaryIDs.contains($0.key) && mediaTime >= $0.value.seconds }
            .sorted { $0.value.seconds < $1.value.seconds }
        for (boundaryID, boundary) in ready {
            firedBoundaryIDs.insert(boundaryID)
            print(
                "[Chapter01DadBattle] media boundary reached " +
                    "boundaryID=\(boundaryID) authoredMediaTime=\(boundary.seconds) " +
                    "observedMediaTime=\(mediaTime) playbackID=\(epoch.playbackID.uuidString)"
            )
            boundary.callback(epoch)
        }
    }

    private func finish(player: AVAudioPlayer, successfully: Bool) {
        guard self.player === player else { return }
        terminalMediaTime = max(preparedDuration, player.duration)
        self.player = nil
        reconcileBoundaries()
        print(
            "[Chapter01DadBattle] music completed successfully=\(successfully) " +
                "terminalMediaTime=\(terminalMediaTime ?? 0)"
        )
    }

    private static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
