import AVFoundation
import Foundation

actor TuringGlobalAudioPlayerActor: TuringAudioPlaybackEndpoint {
    private struct Active {
        let handle: TuringAudioPlaybackHandle
        let player: AVAudioPlayer
        let playerID: ObjectIdentifier
    }

    private nonisolated final class DelegateProxy:
        NSObject,
        AVAudioPlayerDelegate,
        @unchecked Sendable
    {
        weak var owner: TuringGlobalAudioPlayerActor?

        nonisolated func audioPlayerDidFinishPlaying(
            _ player: AVAudioPlayer,
            successfully flag: Bool
        ) {
            let playerID = ObjectIdentifier(player)
            Task {
                await owner?.finished(
                    playerID: playerID,
                    successfully: flag
                )
            }
        }

        nonisolated func audioPlayerDecodeErrorDidOccur(
            _ player: AVAudioPlayer,
            error: Error?
        ) {
            let playerID = ObjectIdentifier(player)
            Task {
                await owner?.finished(
                    playerID: playerID,
                    successfully: false
                )
            }
        }
    }

    private lazy var delegateProxy: DelegateProxy = {
        let proxy = DelegateProxy()
        proxy.owner = self
        return proxy
    }()
    private var active: Active?
    private let eventHub = TuringAudioEventHub()

    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle {
        TuringAudioOffloadSignposts.assertNotMainThread("AVAudioPlayer.init")
        TuringAudioOffloadSignposts.offMain(
            "AVAudioPlayer.init",
            file: request.fileURL.lastPathComponent
        )
        guard active == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Global audio endpoint already owns a clip."
            )
        }
        let player = try AVAudioPlayer(contentsOf: request.fileURL)
        player.numberOfLoops = request.shouldLoop ? -1 : 0
        player.volume = min(1, max(0, pow(10, request.gainDB / 20)))
        player.delegate = delegateProxy
        guard player.prepareToPlay(), player.play() else {
            player.delegate = nil
            throw TuringRuntimeError.invalidConfig(
                "Global audio endpoint failed to start \(request.label)."
            )
        }
        let clockOrigin = ContinuousClock.now
        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: request.requestID,
            runID: request.runID,
            route: request.route
        )
        active = Active(
            handle: handle,
            player: player,
            playerID: ObjectIdentifier(player)
        )
        await eventHub.yield(
            .started(
                handle: handle,
                clockOrigin: clockOrigin
            )
        )
        return handle
    }

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        guard let active, active.handle == handle else { return }
        self.active = nil
        active.player.delegate = nil
        active.player.stop()
        await eventHub.yield(.cancelled(handle, reason: reason))
    }

    func pause(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async throws {
        guard let active, active.handle == handle else {
            throw TuringRuntimeError.invalidConfig(
                "Global playback handle is stale."
            )
        }
        active.player.pause()
        let instant = ContinuousClock.now
        await eventHub.yield(
            .paused(
                handle: handle,
                instant: instant,
                reason: reason
            )
        )
    }

    func resume(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async throws {
        guard let active,
              active.handle == handle,
              active.player.play() else {
            throw TuringRuntimeError.invalidConfig(
                "Global playback failed to resume."
            )
        }
        let instant = ContinuousClock.now
        await eventHub.yield(
            .resumed(
                handle: handle,
                instant: instant,
                reason: reason
            )
        )
    }

    fileprivate func finished(
        playerID: ObjectIdentifier,
        successfully: Bool
    ) async {
        guard let active, active.playerID == playerID else { return }
        self.active = nil
        active.player.delegate = nil
        await eventHub.yield(
            .completed(active.handle, successfully: successfully)
        )
    }

    func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
        await eventHub.stream()
    }
}
