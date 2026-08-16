import AVFoundation
import Foundation

actor Chapter03LightTunnelMusicController {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var activeRunID: UUID?
    private var durationSeconds: Double = 0
    private var gainRampTask: Task<Void, Never>?

    func prepareAndPlay(
        runID: UUID,
        resourceURL: URL,
        definition: Chapter03LightTunnelMusicDefinition
    ) async throws -> AsyncThrowingStream<Event, Error> {
        await stopCurrent(reason: "replacement")
        let asset = AVURLAsset(url: resourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite,
              duration >= definition.minimumDurationSeconds,
              duration <= definition.maximumDurationSeconds +
                Chapter03LightTunnelDefinitionStore
                .encodedAudioPaddingToleranceSeconds else {
            throw Chapter03Error.musicDurationInvalid(duration)
        }
        let playable = try await asset.load(.isPlayable)
        guard playable else {
            throw Chapter03Error.musicPlaybackFailed("asset is not playable")
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.volume = definition.fadeInSeconds > 0
            ? 0
            : Self.linearGain(decibels: definition.gainDB)

        let stream = AsyncThrowingStream<Event, Error> { continuation in
            self.continuation = continuation
        }
        self.player = player
        playerItem = item
        activeRunID = runID
        durationSeconds = duration

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleCompletion(runID: runID) }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: nil
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "AVPlayerItem failed"
            Task { await self?.handleFailure(message, runID: runID) }
        }
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: DispatchQueue.global(qos: .userInteractive)
        ) { [weak self] time in
            Task {
                await self?.publishMediaTime(
                    time.seconds,
                    runID: runID
                )
            }
        }

        self.continuation?.yield(.prepared(durationSeconds: duration))
        player.play()
        self.continuation?.yield(.started)
        if definition.fadeInSeconds > 0 {
            startGainRamp(
                to: definition.gainDB,
                seconds: definition.fadeInSeconds,
                runID: runID
            )
        }
        print(
            "[Chapter03Music] started runID=\(runID.uuidString) " +
                "duration=\(duration) gainDB=\(definition.gainDB) streaming=true"
        )
        return stream
    }

    func setGainDB(
        _ gainDB: Float,
        rampSeconds: Double,
        runID: UUID
    ) async throws {
        guard activeRunID == runID else { throw Chapter03Error.staleRun }
        startGainRamp(to: gainDB, seconds: rampSeconds, runID: runID)
    }

    func stop(runID: UUID, reason: String) async {
        guard activeRunID == runID else { return }
        await stopCurrent(reason: reason)
    }

    var activePlayerCount: Int { player == nil ? 0 : 1 }
    var activeTimeObserverCount: Int { periodicObserver == nil ? 0 : 1 }

    private func publishMediaTime(_ seconds: Double, runID: UUID) {
        guard activeRunID == runID, seconds.isFinite else { return }
        continuation?.yield(
            .mediaTime(seconds: seconds, durationSeconds: durationSeconds)
        )
    }

    private func handleCompletion(runID: UUID) async {
        guard activeRunID == runID else { return }
        continuation?.yield(.completed)
        continuation?.finish()
        print("[Chapter03Music] actual completion runID=\(runID.uuidString)")
    }

    private func handleFailure(_ message: String, runID: UUID) async {
        guard activeRunID == runID else { return }
        continuation?.yield(.failed(message))
        continuation?.finish(
            throwing: Chapter03Error.musicPlaybackFailed(message)
        )
    }

    private func startGainRamp(to gainDB: Float, seconds: Double, runID: UUID) {
        gainRampTask?.cancel()
        gainRampTask = Task { [weak self] in
            await self?.rampGain(to: gainDB, seconds: seconds, runID: runID)
        }
    }

    private func rampGain(to gainDB: Float, seconds: Double, runID: UUID) async {
        guard activeRunID == runID, let player else { return }
        let start = player.volume
        let target = Self.linearGain(decibels: gainDB)
        let steps = max(1, Int(seconds * 30))
        for step in 1...steps {
            guard !Task.isCancelled, activeRunID == runID else { return }
            let t = Float(step) / Float(steps)
            player.volume = start + (target - start) * t
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private func stopCurrent(reason: String) async {
        gainRampTask?.cancel()
        gainRampTask = nil
        if let periodicObserver, let player {
            player.removeTimeObserver(periodicObserver)
        }
        periodicObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        endObserver = nil
        failureObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        continuation?.finish()
        continuation = nil
        let stoppedRunID = activeRunID
        activeRunID = nil
        durationSeconds = 0
        if let stoppedRunID {
            print("[Chapter03Music] released runID=\(stoppedRunID.uuidString) reason=\(reason)")
        }
    }

    private static func linearGain(decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}
