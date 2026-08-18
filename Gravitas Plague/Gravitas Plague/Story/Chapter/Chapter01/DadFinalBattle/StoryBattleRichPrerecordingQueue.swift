import AVFoundation
import Foundation

nonisolated struct StoryBattlePrerecordingStartedEvent:
    Sendable,
    Equatable
{
    let battleInstanceID: UUID
    let cueID: String
    let prerecordingID: String
    let playbackID: UUID
}

@MainActor
final class StoryBattleRichPrerecordingQueue: NSObject, AVAudioPlayerDelegate {
    enum QueueError: LocalizedError {
        case playbackDidNotStart
        case interrupted(String)

        var errorDescription: String? {
            switch self {
            case .playbackDidNotStart:
                return "The authored Rich battle recording did not start."
            case .interrupted(let reason):
                return "The authored Rich battle recording was interrupted: \(reason)"
            }
        }
    }

    struct Cue {
        let cueID: String
        let order: Int
        let descriptor: TuringPrerecordingDescriptor
        let fileURL: URL
        let battleInstanceID: UUID
        let gainDB: Float
    }

    private struct CueKey: Hashable {
        let battleInstanceID: UUID
        let cueID: String
    }

    private var reserved: [CueKey: Cue] = [:]
    private var pending: [Cue] = []
    private var requested = Set<CueKey>()
    private var activeCue: Cue?
    private var activePlayer: AVAudioPlayer?
    private var activePlaybackID: UUID?
    private var activeBattleSpeechToken: StoryRichBattleSpeechToken?
    private let richVocalChannel: any StoryRichVocalChannelControlling
    private var cueWaiters: [CueKey: [CheckedContinuation<Void, Error>]] = [:]
    private var drainWaiters:
        [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var onActualPlaybackStarted:
        ((StoryBattlePrerecordingStartedEvent) -> Void)?

    init(richVocalChannel: any StoryRichVocalChannelControlling) {
        self.richVocalChannel = richVocalChannel
        super.init()
    }

    func reserve(_ cue: Cue) {
        let key = CueKey(
            battleInstanceID: cue.battleInstanceID,
            cueID: cue.cueID
        )
        guard requested.insert(key).inserted else { return }
        reserved[key] = cue
        print(
            "[StoryBattleRichPR] reserved battleInstanceID=\(cue.battleInstanceID.uuidString) " +
                "cueID=\(cue.cueID) order=\(cue.order)"
        )
    }

    func enqueue(_ cue: Cue) {
        let key = CueKey(
            battleInstanceID: cue.battleInstanceID,
            cueID: cue.cueID
        )
        if let reservedCue = reserved.removeValue(forKey: key) {
            pending.append(reservedCue)
        } else {
            guard requested.insert(key).inserted else { return }
            pending.append(cue)
        }
        pending.sort { $0.order < $1.order }
        print(
            "[StoryBattleRichPR] enqueued battleInstanceID=\(cue.battleInstanceID.uuidString) " +
                "cueID=\(cue.cueID) pendingCount=\(pending.count)"
        )
        reconcile()
    }

    func enqueueAndWait(_ cue: Cue) async throws {
        let key = CueKey(
            battleInstanceID: cue.battleInstanceID,
            cueID: cue.cueID
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            cueWaiters[key, default: []].append(continuation)
            enqueue(cue)
        }
    }

    func releaseReservationAndEnqueue(
        cueID: String,
        battleInstanceID: UUID
    ) {
        let key = CueKey(
            battleInstanceID: battleInstanceID,
            cueID: cueID
        )
        guard let cue = reserved.removeValue(forKey: key) else { return }
        pending.append(cue)
        pending.sort { $0.order < $1.order }
        reconcile()
    }

    func waitUntilDrained(battleInstanceID: UUID) async {
        guard !isDrained(battleInstanceID: battleInstanceID) else { return }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            drainWaiters[battleInstanceID, default: [:]][waiterID] = continuation
        }
    }

    func isDrained(battleInstanceID: UUID) -> Bool {
        activeCue?.battleInstanceID != battleInstanceID &&
            pending.contains(where: { $0.battleInstanceID == battleInstanceID }) == false &&
            reserved.values.contains(where: {
                $0.battleInstanceID == battleInstanceID
            }) == false
    }

    func cancel(battleInstanceID: UUID? = nil, reason: String) {
        let applies: (UUID) -> Bool = { id in
            battleInstanceID == nil || battleInstanceID == id
        }
        pending.removeAll { cue in
            guard applies(cue.battleInstanceID) else { return false }
            failWaiters(for: cue, reason: reason)
            return true
        }
        let reservedCues = reserved.filter {
            applies($0.value.battleInstanceID)
        }
        for (key, cue) in reservedCues {
            reserved.removeValue(forKey: key)
            failWaiters(for: cue, reason: reason)
        }
        if let activeCue, applies(activeCue.battleInstanceID) {
            activePlayer?.stop()
            finishActive(successfully: false, reason: reason)
        }
        requested = requested.filter { !applies($0.battleInstanceID) }
        if let battleInstanceID {
            resumeDrainWaiters(battleInstanceID: battleInstanceID)
        } else {
            onActualPlaybackStarted = nil
            for id in drainWaiters.keys {
                resumeDrainWaiters(battleInstanceID: id)
            }
        }
        reconcile()
    }

    private func reconcile() {
        guard activePlayer == nil, let next = pending.first else { return }
        let blockingReservation = reserved.values.contains {
            $0.battleInstanceID == next.battleInstanceID && $0.order < next.order
        }
        guard !blockingReservation else { return }
        pending.removeFirst()
        do {
            let player = try AVAudioPlayer(contentsOf: next.fileURL)
            player.delegate = self
            player.numberOfLoops = 0
            player.volume = Self.linearGain(decibels: next.gainDB)
            player.prepareToPlay()
            let playbackID = UUID()
            activeCue = next
            activePlayer = player
            activePlaybackID = playbackID
            guard player.play() else {
                activeCue = nil
                activePlayer = nil
                activePlaybackID = nil
                throw QueueError.playbackDidNotStart
            }
            activeBattleSpeechToken = richVocalChannel.beginBattleSpeech(
                battleInstanceID: next.battleInstanceID,
                cueID: next.cueID,
                playbackID: playbackID
            )
            onActualPlaybackStarted?(
                StoryBattlePrerecordingStartedEvent(
                    battleInstanceID: next.battleInstanceID,
                    cueID: next.cueID,
                    prerecordingID: next.descriptor.prerecordingID,
                    playbackID: playbackID
                )
            )
            print(
                "[StoryBattleRichPR] actual start " +
                    "battleInstanceID=\(next.battleInstanceID.uuidString) " +
                    "cueID=\(next.cueID) prerecordingID=\(next.descriptor.prerecordingID) " +
                    "route=global gainDB=\(next.gainDB) generatedTTS=false"
            )
        } catch {
            failWaiters(for: next, error: error)
            requested.remove(
                CueKey(
                    battleInstanceID: next.battleInstanceID,
                    cueID: next.cueID
                )
            )
            resumeDrainWaitersIfNeeded(battleInstanceID: next.battleInstanceID)
            reconcile()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard self?.activePlayer === player else { return }
            self?.finishActive(
                successfully: flag,
                reason: flag ? "actualCompletion" : "delegateUnsuccessful"
            )
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard self?.activePlayer === player else { return }
            self?.finishActive(
                successfully: false,
                reason: error?.localizedDescription ?? "decodeError"
            )
        }
    }

    private func finishActive(successfully: Bool, reason: String) {
        guard let cue = activeCue else { return }
        if let activeBattleSpeechToken {
            richVocalChannel.endBattleSpeech(
                token: activeBattleSpeechToken,
                reason: reason
            )
            self.activeBattleSpeechToken = nil
        }
        activePlayer = nil
        activeCue = nil
        activePlaybackID = nil
        let key = CueKey(
            battleInstanceID: cue.battleInstanceID,
            cueID: cue.cueID
        )
        let waiters = cueWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters {
            if successfully {
                waiter.resume()
            } else {
                waiter.resume(throwing: QueueError.interrupted(reason))
            }
        }
        print(
            "[StoryBattleRichPR] completed battleInstanceID=\(cue.battleInstanceID.uuidString) " +
                "cueID=\(cue.cueID) successfully=\(successfully) reason=\(reason)"
        )
        resumeDrainWaitersIfNeeded(battleInstanceID: cue.battleInstanceID)
        reconcile()
    }

    private func failWaiters(for cue: Cue, reason: String) {
        failWaiters(for: cue, error: QueueError.interrupted(reason))
    }

    private func failWaiters(for cue: Cue, error: Error) {
        let key = CueKey(
            battleInstanceID: cue.battleInstanceID,
            cueID: cue.cueID
        )
        let waiters = cueWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func resumeDrainWaitersIfNeeded(battleInstanceID: UUID) {
        guard isDrained(battleInstanceID: battleInstanceID) else { return }
        resumeDrainWaiters(battleInstanceID: battleInstanceID)
    }

    private func resumeDrainWaiters(battleInstanceID: UUID) {
        guard let waitersByID = drainWaiters.removeValue(
            forKey: battleInstanceID
        ) else { return }
        let waiters = Array(waitersByID.values)
        for waiter in waiters { waiter.resume() }
    }

    private static func linearGain(decibels: Float) -> Float {
        min(1, max(0, powf(10, decibels / 20)))
    }
}

extension StoryBattleRichPrerecordingQueue: Battle01RichPrerecordingPlaying {
    func play(
        descriptor: TuringPrerecordingDescriptor,
        fileURL: URL,
        battleInstanceID: UUID
    ) async throws {
        let cueID = descriptor.prerecordingID
        let cue = Cue(
            cueID: cueID,
            order: 0,
            descriptor: descriptor,
            fileURL: fileURL,
            battleInstanceID: battleInstanceID,
            gainDB: -5
        )
        let key = CueKey(
            battleInstanceID: battleInstanceID,
            cueID: cueID
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            cueWaiters[key, default: []].append(continuation)
            enqueue(cue)
        }
    }

    func cancel(reason: String) {
        cancel(battleInstanceID: nil, reason: reason)
    }
}
