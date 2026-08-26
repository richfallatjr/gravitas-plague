import AVFoundation
import Foundation

enum Chapter03BattleMusicLane: String, Sendable, CaseIterable {
    case biker
    case bigMikePhaseOne
    case bigMikePhaseTwo
}

struct Chapter03BattleMusicEpoch: Sendable, Hashable {
    let lane: Chapter03BattleMusicLane
    let battleInstanceID: UUID
    let playbackID: UUID
    let triggerEventID: UUID
}

struct Chapter03BattleMusicCrossfade: Sendable {
    let outgoingEpoch: Chapter03BattleMusicEpoch?
    let incomingEpoch: Chapter03BattleMusicEpoch
    let durationSeconds: TimeInterval
}

@MainActor
final class Chapter03BattleMusicController: NSObject, AVAudioPlayerDelegate {
    enum MusicError: LocalizedError {
        case laneNotPrepared(String)
        case playbackDidNotStart(String)

        var errorDescription: String? {
            switch self {
            case .laneNotPrepared(let lane):
                return "Chapter 3 battle music lane is not prepared: \(lane)."
            case .playbackDidNotStart(let lane):
                return "Chapter 3 battle music did not start: \(lane)."
            }
        }
    }

    private struct Prepared {
        let url: URL
        let gainDB: Float
        let loop: Bool
    }

    private var prepared: [Chapter03BattleMusicLane: Prepared] = [:]
    private var players: [Chapter03BattleMusicEpoch: AVAudioPlayer] = [:]

    var activeHandleCount: Int { players.count }

    func prepare(definition: Chapter03BattleDefinition) throws {
        prepared.removeAll(keepingCapacity: true)
        for item in definition.music {
            guard let lane = Chapter03BattleMusicLane(rawValue: item.lane) else {
                throw Chapter03Error.definitionInvalid("Unknown music lane \(item.lane).")
            }
            let url = try TuringResourceLoader.resourceURL(
                resourcePath: item.resourcePath
            )
            let validator = try AVAudioPlayer(contentsOf: url)
            guard validator.duration > 0 else {
                throw Chapter03Error.musicDurationInvalid(validator.duration)
            }
            prepared[lane] = Prepared(
                url: url,
                gainDB: item.gainDB,
                loop: item.loop
            )
            print(
                "[Chapter03BattleMusic] prepared lane=\(lane.rawValue) file=\(url.lastPathComponent) gainDB=\(item.gainDB) loop=\(item.loop)"
            )
        }
    }

    @discardableResult
    func start(
        lane: Chapter03BattleMusicLane,
        battleInstanceID: UUID,
        triggerEventID: UUID,
        fadeInSeconds: TimeInterval = 0
    ) throws -> Chapter03BattleMusicEpoch {
        if let existing = players.keys.first(where: {
            $0.lane == lane && $0.battleInstanceID == battleInstanceID
        }) {
            return existing
        }
        guard let item = prepared[lane] else {
            throw MusicError.laneNotPrepared(lane.rawValue)
        }
        let player = try AVAudioPlayer(contentsOf: item.url)
        player.delegate = self
        player.numberOfLoops = item.loop ? -1 : 0
        let target = Self.linearGain(decibels: item.gainDB)
        player.volume = fadeInSeconds > 0 ? 0 : target
        player.prepareToPlay()
        guard player.play() else {
            throw MusicError.playbackDidNotStart(lane.rawValue)
        }
        if fadeInSeconds > 0 {
            player.setVolume(target, fadeDuration: fadeInSeconds)
        }
        let epoch = Chapter03BattleMusicEpoch(
            lane: lane,
            battleInstanceID: battleInstanceID,
            playbackID: UUID(),
            triggerEventID: triggerEventID
        )
        players[epoch] = player
        TuringProductionDiagnostics.recordSignal(
            "chapter03BattleMusic.actualStart",
            details: [
                "battleInstanceID": battleInstanceID.uuidString,
                "file": item.url.lastPathComponent,
                "gainDB": String(item.gainDB),
                "isPlaying": String(player.isPlaying),
                "lane": lane.rawValue,
                "playbackID": epoch.playbackID.uuidString,
                "triggerEventID": triggerEventID.uuidString
            ]
        )
        print(
            "[Chapter03BattleMusic] actual start lane=\(lane.rawValue) battleInstanceID=\(battleInstanceID.uuidString) playbackID=\(epoch.playbackID.uuidString) triggerEventID=\(triggerEventID.uuidString) gainDB=\(item.gainDB)"
        )
        return epoch
    }

    func beginCrossfade(
        from oldEpoch: Chapter03BattleMusicEpoch?,
        to lane: Chapter03BattleMusicLane,
        battleInstanceID: UUID,
        triggerEventID: UUID,
        durationSeconds: TimeInterval
    ) throws -> Chapter03BattleMusicCrossfade {
        let duration = max(0, durationSeconds)

        // Start the incoming score synchronously at its authored gain. The
        // surrender PR callback is the authored boundary, so it must return
        // only after phase two has actually entered AVAudioPlayer playback.
        // Phase one may fade away underneath it, but phase two is never
        // deferred to a child task or faded up from digital silence.
        let next = try start(
            lane: lane,
            battleInstanceID: battleInstanceID,
            triggerEventID: triggerEventID
        )
        if let oldEpoch, let oldPlayer = players[oldEpoch] {
            oldPlayer.setVolume(0, fadeDuration: duration)
        }
        print(
            "[Chapter03BattleMusic] crossfade began synchronously " +
                "to=\(lane.rawValue) duration=\(duration) " +
                "incomingStartsAtAuthoredGain=true"
        )
        return Chapter03BattleMusicCrossfade(
            outgoingEpoch: oldEpoch,
            incomingEpoch: next,
            durationSeconds: duration
        )
    }

    func completeCrossfade(
        _ transition: Chapter03BattleMusicCrossfade
    ) async throws -> Chapter03BattleMusicEpoch {
        if transition.durationSeconds > 0 {
            try await Task.sleep(
                for: .seconds(transition.durationSeconds)
            )
        }
        if let oldEpoch = transition.outgoingEpoch {
            stop(epoch: oldEpoch, reason: "crossfadeCompleted")
        }
        print(
            "[Chapter03BattleMusic] crossfade completed " +
                "to=\(transition.incomingEpoch.lane.rawValue) " +
                "duration=\(transition.durationSeconds) " +
                "activeHandles=\(players.count)"
        )
        return transition.incomingEpoch
    }

    func crossfade(
        from oldEpoch: Chapter03BattleMusicEpoch?,
        to lane: Chapter03BattleMusicLane,
        battleInstanceID: UUID,
        triggerEventID: UUID,
        durationSeconds: TimeInterval
    ) async throws -> Chapter03BattleMusicEpoch {
        let transition = try beginCrossfade(
            from: oldEpoch,
            to: lane,
            battleInstanceID: battleInstanceID,
            triggerEventID: triggerEventID,
            durationSeconds: durationSeconds
        )
        return try await completeCrossfade(transition)
    }

    func fadeOutAndStopAll(
        battleInstanceID: UUID,
        durationSeconds: TimeInterval,
        reason: String
    ) async {
        let matches = players.filter { $0.key.battleInstanceID == battleInstanceID }
        let duration = max(0, durationSeconds)
        for player in matches.values {
            player.setVolume(0, fadeDuration: duration)
        }
        if duration > 0 {
            try? await Task.sleep(for: .seconds(duration))
        }
        for epoch in matches.keys {
            stop(epoch: epoch, reason: reason)
        }
    }

    func stop(epoch: Chapter03BattleMusicEpoch?, reason: String) {
        guard let epoch, let player = players.removeValue(forKey: epoch) else { return }
        player.stop()
        print(
            "[Chapter03BattleMusic] stopped lane=\(epoch.lane.rawValue) playbackID=\(epoch.playbackID.uuidString) reason=\(reason)"
        )
    }

    func stopAll(reason: String) {
        let active = players
        players.removeAll(keepingCapacity: false)
        for (epoch, player) in active {
            player.stop()
            print(
                "[Chapter03BattleMusic] stopped lane=\(epoch.lane.rawValue) playbackID=\(epoch.playbackID.uuidString) reason=\(reason)"
            )
        }
        prepared.removeAll(keepingCapacity: false)
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.removeFinished(player, successfully: flag)
        }
    }

    private func removeFinished(_ player: AVAudioPlayer, successfully: Bool) {
        guard let epoch = players.first(where: { $0.value === player })?.key else { return }
        players.removeValue(forKey: epoch)
        print(
            "[Chapter03BattleMusic] completed lane=\(epoch.lane.rawValue) playbackID=\(epoch.playbackID.uuidString) successfully=\(successfully)"
        )
    }

    private static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}
