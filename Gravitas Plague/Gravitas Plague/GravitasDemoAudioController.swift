import AVFoundation
import Foundation

@MainActor
final class GravitasDemoAudioController {
    enum AudioError: LocalizedError {
        case missingResource(String)
        case playerCreationFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Missing audio resource: \(name)"
            case .playerCreationFailed(let name, let error):
                return "Failed to create audio player for \(name): \(error.localizedDescription)"
            }
        }
    }

    private struct AudioResource {
        let fileName: String
        let fileExtension: String

        var fullName: String {
            "\(fileName).\(fileExtension)"
        }
    }

    private let backgroundMusicResource = AudioResource(
        fileName: "GravitasPlagueBackgroundLoop",
        fileExtension: "wav"
    )

    private let radioStaticResource = AudioResource(
        fileName: "Narrow-band-analog",
        fileExtension: "wav"
    )

    private let dadBreathingResource = AudioResource(
        fileName: "dad_breathing",
        fileExtension: "wav"
    )

    private let emergencyBeepResource = AudioResource(
        fileName: "Create_a_short_emerg_beeping",
        fileExtension: "wav"
    )

    private let emergencyBroadcastResource = AudioResource(
        fileName: "EmergencyBroadcast",
        fileExtension: "mp3"
    )

    private let punchResource = AudioResource(
        fileName: "face-punch_mixdown",
        fileExtension: "wav"
    )

    private var backgroundMusicPlayer: AVAudioPlayer?
    private var radioStaticPlayer: AVAudioPlayer?
    private var dadBreathingPlayer: AVAudioPlayer?
    private var emergencyBeepPlayer: AVAudioPlayer?
    private var emergencyBroadcastPlayer: AVAudioPlayer?
    private var punchPlayers: [AVAudioPlayer] = []

    private var emergencyBroadcastTask: Task<Void, Never>?

    private var hasPrepared = false
    private var isImmersiveAudioActive = false
    private var isDemoAudioActive = false

    func prepareIfNeeded() {
        guard !hasPrepared else { return }

        do {
            try configureAudioSession()
        } catch {
            print("[Gravitas Audio] Audio session configuration failed: \(error)")
        }

        backgroundMusicPlayer = makeOptionalPlayer(
            resource: backgroundMusicResource,
            volume: 0.32,
            loopsForever: true
        )

        radioStaticPlayer = makeOptionalPlayer(
            resource: radioStaticResource,
            volume: 0.20,
            loopsForever: true
        )

        dadBreathingPlayer = makeOptionalPlayer(
            resource: dadBreathingResource,
            volume: 0.42,
            loopsForever: true
        )

        emergencyBeepPlayer = makeOptionalPlayer(
            resource: emergencyBeepResource,
            volume: 0.85,
            loopsForever: false
        )

        emergencyBroadcastPlayer = makeOptionalPlayer(
            resource: emergencyBroadcastResource,
            volume: 0.78,
            loopsForever: false
        )

        punchPlayers = makePunchPool(count: 4)
        hasPrepared = true

        print("[Gravitas Audio] Prepared audio resources.")
    }

    func startImmersiveAudio() {
        prepareIfNeeded()

        guard !isImmersiveAudioActive else { return }

        isImmersiveAudioActive = true

        backgroundMusicPlayer?.currentTime = 0
        backgroundMusicPlayer?.play()

        print("[Gravitas Audio] Started immersive background music.")
    }

    func startDemoAudio() {
        prepareIfNeeded()
        startImmersiveAudio()

        guard !isDemoAudioActive else { return }

        isDemoAudioActive = true

        radioStaticPlayer?.currentTime = 0
        radioStaticPlayer?.play()

        dadBreathingPlayer?.currentTime = 0
        dadBreathingPlayer?.play()

        startEmergencyBroadcastLoop()

        print("[Gravitas Audio] Started demo radio static, Dad breathing, and emergency broadcast loop.")
    }

    func stopDemoAudio() {
        guard isDemoAudioActive else { return }

        isDemoAudioActive = false

        radioStaticPlayer?.stop()
        radioStaticPlayer?.currentTime = 0

        dadBreathingPlayer?.stop()
        dadBreathingPlayer?.currentTime = 0

        stopEmergencyBroadcastLoop()

        emergencyBeepPlayer?.stop()
        emergencyBeepPlayer?.currentTime = 0

        emergencyBroadcastPlayer?.stop()
        emergencyBroadcastPlayer?.currentTime = 0

        print("[Gravitas Audio] Stopped demo radio/static/breathing/emergency audio.")
    }

    func stopAllAudio() {
        isDemoAudioActive = false
        isImmersiveAudioActive = false

        stopEmergencyBroadcastLoop()

        backgroundMusicPlayer?.stop()
        backgroundMusicPlayer?.currentTime = 0

        radioStaticPlayer?.stop()
        radioStaticPlayer?.currentTime = 0

        dadBreathingPlayer?.stop()
        dadBreathingPlayer?.currentTime = 0

        emergencyBeepPlayer?.stop()
        emergencyBeepPlayer?.currentTime = 0

        emergencyBroadcastPlayer?.stop()
        emergencyBroadcastPlayer?.currentTime = 0

        for player in punchPlayers {
            player.stop()
            player.currentTime = 0
        }

        print("[Gravitas Audio] Stopped all audio.")
    }

    func playPunchHit() {
        prepareIfNeeded()

        guard let player = nextAvailablePunchPlayer() else {
            print("[Gravitas Audio] No punch player available.")
            return
        }

        player.currentTime = 0
        player.play()
    }

    private func startEmergencyBroadcastLoop() {
        stopEmergencyBroadcastLoop()

        emergencyBroadcastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            while !Task.isCancelled {
                await self?.playEmergencyBroadcastSequence()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func stopEmergencyBroadcastLoop() {
        emergencyBroadcastTask?.cancel()
        emergencyBroadcastTask = nil
    }

    private func playEmergencyBroadcastSequence() async {
        guard isDemoAudioActive else { return }

        emergencyBeepPlayer?.stop()
        emergencyBeepPlayer?.currentTime = 0
        emergencyBeepPlayer?.play()

        try? await Task.sleep(nanoseconds: 850_000_000)

        guard isDemoAudioActive else { return }

        emergencyBroadcastPlayer?.stop()
        emergencyBroadcastPlayer?.currentTime = 0
        emergencyBroadcastPlayer?.play()

        print("[Gravitas Audio] Played emergency broadcast sequence.")
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .ambient,
            mode: .default,
            options: [
                .mixWithOthers
            ]
        )

        try session.setActive(true)
    }

    private func makeOptionalPlayer(
        resource: AudioResource,
        volume: Float,
        loopsForever: Bool
    ) -> AVAudioPlayer? {
        do {
            return try makePlayer(
                resource: resource,
                volume: volume,
                loopsForever: loopsForever
            )
        } catch {
            print("[Gravitas Audio] \(error)")
            return nil
        }
    }

    private func makePlayer(
        resource: AudioResource,
        volume: Float,
        loopsForever: Bool
    ) throws -> AVAudioPlayer {
        guard let url = Bundle.main.url(
            forResource: resource.fileName,
            withExtension: resource.fileExtension
        ) else {
            throw AudioError.missingResource(resource.fullName)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.numberOfLoops = loopsForever ? -1 : 0
            player.prepareToPlay()
            return player
        } catch {
            throw AudioError.playerCreationFailed(resource.fullName, error)
        }
    }

    private func makePunchPool(count: Int) -> [AVAudioPlayer] {
        var players: [AVAudioPlayer] = []

        for _ in 0..<count {
            if let player = makeOptionalPlayer(
                resource: punchResource,
                volume: 0.95,
                loopsForever: false
            ) {
                players.append(player)
            }
        }

        return players
    }

    private func nextAvailablePunchPlayer() -> AVAudioPlayer? {
        if let idle = punchPlayers.first(where: { !$0.isPlaying }) {
            return idle
        }

        return punchPlayers.first
    }
}
