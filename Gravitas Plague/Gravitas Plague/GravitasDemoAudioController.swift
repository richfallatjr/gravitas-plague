import AVFoundation
import Foundation
import RealityKit
import simd

@MainActor
final class GravitasDemoAudioController {
    enum AudioError: LocalizedError {
        case missingResource(String)
        case playerCreationFailed(String, Error)
        case resourceLoadFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Missing audio resource: \(name)"
            case .playerCreationFailed(let name, let error):
                return "Failed to create audio player for \(name): \(error.localizedDescription)"
            case .resourceLoadFailed(let name, let error):
                return "Failed to load RealityKit audio resource \(name): \(error.localizedDescription)"
            }
        }
    }

    private struct BundleAudioFile {
        let fileName: String
        let fileExtension: String

        var fullName: String {
            "\(fileName).\(fileExtension)"
        }
    }

    private struct HostAudioSource {
        let headEntity: Entity
        var dadBreathingController: AudioPlaybackController?
        var breathingStartTask: Task<Void, Never>?
        var punchControllers: [AudioPlaybackController]
    }

    private let backgroundMusicFile = BundleAudioFile(
        fileName: "GravitasPlagueBackgroundLoop",
        fileExtension: "wav"
    )

    private let radioStaticFile = BundleAudioFile(
        fileName: "Narrow-band-analog",
        fileExtension: "wav"
    )

    private let dadBreathingFile = BundleAudioFile(
        fileName: "dad_breathing",
        fileExtension: "wav"
    )

    private let emergencyBeepFile = BundleAudioFile(
        fileName: "Create_a_short_emerg_beeping",
        fileExtension: "wav"
    )

    private let emergencyBroadcastFile = BundleAudioFile(
        fileName: "EmergencyBroadcast",
        fileExtension: "mp3"
    )

    private let punchFile = BundleAudioFile(
        fileName: "face-punch_mixdown",
        fileExtension: "wav"
    )

    private let playerDamageFiles: [BundleAudioFile] = [
        BundleAudioFile(fileName: "damaged-01", fileExtension: "wav"),
        BundleAudioFile(fileName: "damaged-02", fileExtension: "wav"),
        BundleAudioFile(fileName: "damaged-03", fileExtension: "wav"),
        BundleAudioFile(fileName: "damaged-04", fileExtension: "wav")
    ]

    private let playerDeathFiles: [BundleAudioFile] = [
        BundleAudioFile(fileName: "die_01", fileExtension: "wav"),
        BundleAudioFile(fileName: "die_02", fileExtension: "wav")
    ]

    private var backgroundMusicPlayer: AVAudioPlayer?
    private var playerDamagePlayersByFileName: [String: AVAudioPlayer] = [:]
    private var lastPlayerDamageFileName: String?
    private var playerDeathPlayersByFileName: [String: AVAudioPlayer] = [:]
    private var lastPlayerDeathFileName: String?

    private let radioAudioEntity = Entity()
    private let hostHeadAudioEntity = Entity()

    private weak var sceneRoot: Entity?
    private weak var hostRootEntity: Entity?

    private var radioStaticResource: AudioFileResource?
    private var dadBreathingResource: AudioFileResource?
    private var emergencyBeepResource: AudioFileResource?
    private var emergencyBroadcastResource: AudioFileResource?
    private var punchResource: AudioFileResource?

    private var radioStaticController: AudioPlaybackController?
    private var dadBreathingController: AudioPlaybackController?
    private var emergencyBeepController: AudioPlaybackController?
    private var emergencyBroadcastController: AudioPlaybackController?
    private var punchControllers: [AudioPlaybackController] = []
    private var hostAudioSourcesByID: [UUID: HostAudioSource] = [:]

    private var emergencyBroadcastTask: Task<Void, Never>?

    private var hasPrepared = false
    private var hasAttachedEntities = false
    private var hasAttachedRadioEntity = false
    private var hasAttachedHostHeadEntity = false
    private var isImmersiveAudioActive = false
    private var isDemoAudioActive = false

    private let feetToMeters: Float = 0.3048
    private let radioDistanceBehindUserFeet: Float = 5.0
    private let hostHeadAudioLocalPosition = SIMD3<Float>(0, 1.45, -0.04)

    private let emergencyInitialDelaySeconds: TimeInterval = 30.0
    private let emergencyBreakAfterBroadcastSeconds: TimeInterval = 30.0
    private let emergencyBeatDelaySeconds: TimeInterval = 0.85
    private let emergencyBeepDecibels: Float = -23.0

    func attachToSceneIfNeeded(
        sceneRoot: Entity,
        hostRootEntity: Entity
    ) {
        self.sceneRoot = sceneRoot
        self.hostRootEntity = hostRootEntity

        attachRadioEntityIfNeeded(
            to: sceneRoot
        )

        attachHostHeadEntityIfNeeded(
            to: hostRootEntity
        )

        guard !hasAttachedEntities else { return }

        hasAttachedEntities = hasAttachedRadioEntity && hasAttachedHostHeadEntity

        print("[Gravitas Audio] Spatial audio entities attached.")
    }

    func attachRadioToSceneIfNeeded(
        sceneRoot: Entity
    ) {
        self.sceneRoot = sceneRoot

        attachRadioEntityIfNeeded(
            to: sceneRoot
        )
    }

    private func attachRadioEntityIfNeeded(
        to sceneRoot: Entity
    ) {
        guard !hasAttachedRadioEntity else {
            return
        }

        radioAudioEntity.name = "Gravitas_SpatialRadioAudioSource"
        radioAudioEntity.components.set(SpatialAudioComponent())
        sceneRoot.addChild(radioAudioEntity)

        hasAttachedRadioEntity = true

        print("[Gravitas Audio] Radio spatial audio entity attached.")
    }

    private func attachHostHeadEntityIfNeeded(
        to hostRootEntity: Entity
    ) {
        guard !hasAttachedHostHeadEntity else {
            return
        }

        hostHeadAudioEntity.name = "Gravitas_HostHeadAudioSource"
        hostHeadAudioEntity.components.set(SpatialAudioComponent())
        hostRootEntity.addChild(hostHeadAudioEntity)

        hostHeadAudioEntity.position = hostHeadAudioLocalPosition

        hasAttachedHostHeadEntity = true
    }

    func prepareIfNeeded() {
        guard !hasPrepared else { return }

        do {
            try configureAudioSession()
        } catch {
            print("[Gravitas Audio] Audio session configuration failed: \(error)")
        }

        backgroundMusicPlayer = makeOptionalAVAudioPlayer(
            file: backgroundMusicFile,
            volume: 0.30,
            loopsForever: true
        )

        radioStaticResource = makeOptionalSpatialResource(
            file: radioStaticFile,
            shouldLoop: true
        )

        dadBreathingResource = makeOptionalSpatialResource(
            file: dadBreathingFile,
            shouldLoop: true
        )

        emergencyBeepResource = makeOptionalSpatialResource(
            file: emergencyBeepFile,
            shouldLoop: false
        )

        emergencyBroadcastResource = makeOptionalSpatialResource(
            file: emergencyBroadcastFile,
            shouldLoop: false
        )

        punchResource = makeOptionalSpatialResource(
            file: punchFile,
            shouldLoop: false
        )

        playerDamagePlayersByFileName = makePlayerDamagePlayers()
        playerDeathPlayersByFileName = makePlayerDeathPlayers()

        hasPrepared = true

        print("[Gravitas Audio] Prepared global and spatial audio resources.")
        print("[Gravitas Audio] Emergency beep gain set to \(emergencyBeepDecibels) dB.")
    }

    func configureRadioSourceBehindOriginalUserSpawn(
        spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        let forward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(
                spawnPose.headForward.x,
                0,
                spawnPose.headForward.z
            ),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let behind = -forward
        let distanceMeters = radioDistanceBehindUserFeet * feetToMeters

        let position = SIMD3<Float>(
            spawnPose.headPosition.x + behind.x * distanceMeters,
            floorY + 1.10,
            spawnPose.headPosition.z + behind.z * distanceMeters
        )

        radioAudioEntity.position = position

        print(
            """
            [Gravitas Audio] Radio spatial source placed
              position: \(position)
              distanceBehindFeet: \(radioDistanceBehindUserFeet)
            """
        )
    }

    func updateHostHeadAudioLocalPosition(
        _ localPosition: SIMD3<Float> = SIMD3<Float>(0, 1.45, -0.04)
    ) {
        hostHeadAudioEntity.position = localPosition
    }

    func startPrimaryHostDadBreathing() {
        prepareIfNeeded()
        startDadBreathing()
    }

    func stopPrimaryHostDadBreathing() {
        dadBreathingController?.stop()
        dadBreathingController = nil
    }

    func attachHostAudioSource(
        id: UUID,
        hostRootEntity: Entity,
        breathingStartDelay: TimeInterval = TimeInterval.random(in: 0...1)
    ) {
        prepareIfNeeded()
        stopHostAudioSource(id: id)

        let headEntity = Entity()
        headEntity.name = "Gravitas_HordeHostHeadAudioSource_\(id.uuidString.prefix(6))"
        headEntity.components.set(SpatialAudioComponent())
        headEntity.position = hostHeadAudioLocalPosition
        hostRootEntity.addChild(headEntity)

        hostAudioSourcesByID[id] = HostAudioSource(
            headEntity: headEntity,
            dadBreathingController: nil,
            breathingStartTask: nil,
            punchControllers: []
        )

        startDadBreathing(
            sourceID: id,
            delay: breathingStartDelay
        )

        print(
            """
            [Gravitas Audio] Attached horde host audio source
              id: \(id)
              breathingStartDelay: \(String(format: "%.3f", breathingStartDelay))
              parent: hostRootEntity
            """
        )
    }

    func stopHostAudioSource(
        id: UUID
    ) {
        guard var source = hostAudioSourcesByID.removeValue(forKey: id) else {
            return
        }

        source.breathingStartTask?.cancel()
        source.breathingStartTask = nil

        source.dadBreathingController?.stop()
        source.dadBreathingController = nil

        for controller in source.punchControllers {
            controller.stop()
        }
        source.punchControllers.removeAll()

        source.headEntity.removeFromParent()

        print("[Gravitas Audio] Stopped horde host audio source: \(id)")
    }

    func stopHostDadBreathing(
        id: UUID
    ) {
        guard var source = hostAudioSourcesByID[id] else {
            return
        }

        source.breathingStartTask?.cancel()
        source.breathingStartTask = nil

        source.dadBreathingController?.stop()
        source.dadBreathingController = nil

        hostAudioSourcesByID[id] = source

        print("[Gravitas Audio] Stopped horde Dad breathing: \(id)")
    }

    func startImmersiveAudio() {
        prepareIfNeeded()

        guard !isImmersiveAudioActive else { return }

        isImmersiveAudioActive = true

        backgroundMusicPlayer?.currentTime = 0
        backgroundMusicPlayer?.play()

        print("[Gravitas Audio] Started global background music.")
    }

    func startDemoAudio(
        spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        prepareIfNeeded()
        startImmersiveAudio()

        configureRadioSourceBehindOriginalUserSpawn(
            spawnPose: spawnPose,
            floorY: floorY
        )

        guard !isDemoAudioActive else { return }

        isDemoAudioActive = true

        startRadioStatic()
        startDadBreathing()
        startEmergencyBroadcastLoop()

        print("[Gravitas Audio] Started spatial demo audio.")
    }

    func startHordeRadioLoop(
        spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        prepareIfNeeded()
        startImmersiveAudio()

        configureRadioSourceBehindOriginalUserSpawn(
            spawnPose: spawnPose,
            floorY: floorY
        )

        if !isDemoAudioActive {
            isDemoAudioActive = true
            startEmergencyBroadcastLoop()
        }

        startRadioStatic()

        print(
            """
            [Gravitas Audio] Started Horde radio loop
              radioStatic: true
              emergencyBroadcastLoop: true
              primaryDadBreathing: false
            """
        )
    }

    func stopDemoAudio() {
        guard isDemoAudioActive else { return }

        isDemoAudioActive = false

        stopEmergencyBroadcastLoop()
        stopSpatialDemoControllers()

        print("[Gravitas Audio] Stopped spatial demo audio.")
    }

    func stopAllAudio() {
        isDemoAudioActive = false
        isImmersiveAudioActive = false

        stopEmergencyBroadcastLoop()

        backgroundMusicPlayer?.stop()
        backgroundMusicPlayer?.currentTime = 0

        stopSpatialDemoControllers()
        stopPlayerDamagePlayers()
        stopPlayerDeathPlayers()

        print("[Gravitas Audio] Stopped all audio.")
    }

    func playPunchHitAtHostHead(
        sourceID: UUID? = nil
    ) {
        prepareIfNeeded()

        guard let punchResource else {
            print("[Gravitas Audio] Punch resource missing.")
            return
        }

        if let sourceID,
           var source = hostAudioSourcesByID[sourceID] {
            let controller = source.headEntity.playAudio(punchResource)
            controller.gain = decibels(linearVolume: 0.95)
            source.punchControllers.append(controller)

            if source.punchControllers.count > 12 {
                source.punchControllers.removeFirst(max(0, source.punchControllers.count - 8))
            }

            hostAudioSourcesByID[sourceID] = source
            return
        }

        let controller = hostHeadAudioEntity.playAudio(punchResource)
        controller.gain = decibels(linearVolume: 0.95)
        punchControllers.append(controller)

        if punchControllers.count > 12 {
            punchControllers.removeFirst(max(0, punchControllers.count - 8))
        }
    }

    func playRandomPlayerDamageHit() {
        prepareIfNeeded()

        guard !playerDamagePlayersByFileName.isEmpty else {
            print("[Gravitas Audio] No player damage sounds available.")
            return
        }

        var candidateFileNames = Array(playerDamagePlayersByFileName.keys)

        if let lastPlayerDamageFileName,
           candidateFileNames.count > 1 {
            candidateFileNames.removeAll { $0 == lastPlayerDamageFileName }
        }

        guard let selectedFileName = candidateFileNames.randomElement(),
              let player = playerDamagePlayersByFileName[selectedFileName] else {
            print("[Gravitas Audio] Failed to select player damage sound.")
            return
        }

        lastPlayerDamageFileName = selectedFileName

        player.stop()
        player.currentTime = 0
        player.play()

        print("[Gravitas Audio] Played player damage sound: \(selectedFileName)")
    }

    func playRandomPlayerDeath() {
        _ = playRandomPlayerDeathAndReturnDuration()
    }

    @discardableResult
    func playRandomPlayerDeathAndReturnDuration() -> TimeInterval {
        prepareIfNeeded()

        guard !playerDeathPlayersByFileName.isEmpty else {
            print("[Gravitas Audio] No player death sounds available.")
            return 0.0
        }

        var candidateFileNames = Array(playerDeathPlayersByFileName.keys)

        if let lastPlayerDeathFileName,
           candidateFileNames.count > 1 {
            candidateFileNames.removeAll { $0 == lastPlayerDeathFileName }
        }

        guard let selectedFileName = candidateFileNames.randomElement(),
              let player = playerDeathPlayersByFileName[selectedFileName] else {
            print("[PlayerDeath] ERROR failed to select player death sound.")
            return 0.0
        }

        player.stop()
        player.currentTime = 0
        player.play()

        lastPlayerDeathFileName = selectedFileName

        print("[PlayerDeath] playing \(selectedFileName).wav")

        return player.duration
    }

    private func startRadioStatic() {
        guard let radioStaticResource else {
            print("[Gravitas Audio] Radio static resource missing.")
            return
        }

        radioStaticController?.stop()
        radioStaticController = radioAudioEntity.playAudio(radioStaticResource)
        radioStaticController?.gain = decibels(linearVolume: 0.20)
    }

    private func startDadBreathing() {
        guard let dadBreathingResource else {
            print("[Gravitas Audio] Dad breathing resource missing.")
            return
        }

        dadBreathingController?.stop()
        dadBreathingController = hostHeadAudioEntity.playAudio(dadBreathingResource)
        dadBreathingController?.gain = decibels(linearVolume: 0.42)
    }

    private func startDadBreathing(
        sourceID: UUID,
        delay: TimeInterval
    ) {
        guard let dadBreathingResource else {
            print("[Gravitas Audio] Dad breathing resource missing.")
            return
        }

        guard var source = hostAudioSourcesByID[sourceID] else {
            print("[Gravitas Audio] Missing horde host audio source for Dad breathing: \(sourceID)")
            return
        }

        source.breathingStartTask?.cancel()
        source.dadBreathingController?.stop()

        if delay <= 0 {
            source.dadBreathingController = source.headEntity.playAudio(dadBreathingResource)
            source.dadBreathingController?.gain = decibels(linearVolume: 0.42)
            source.breathingStartTask = nil
            hostAudioSourcesByID[sourceID] = source

            print(
                """
                [Gravitas Audio] Started horde Dad breathing
                  id: \(sourceID)
                  delayedBy: 0.000
                  immediate: true
                  gatedByDemoAudioActive: false
                """
            )

            return
        }

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )

            guard !Task.isCancelled,
                  let self,
                  let dadBreathingResource = self.dadBreathingResource,
                  var source = self.hostAudioSourcesByID[sourceID] else {
                return
            }

            source.dadBreathingController?.stop()
            source.dadBreathingController = source.headEntity.playAudio(dadBreathingResource)
            source.dadBreathingController?.gain = self.decibels(linearVolume: 0.42)
            source.breathingStartTask = nil
            self.hostAudioSourcesByID[sourceID] = source

            print(
                """
                [Gravitas Audio] Started horde Dad breathing
                  id: \(sourceID)
                  delayedBy: \(String(format: "%.3f", delay))
                  immediate: false
                  gatedByDemoAudioActive: false
                """
            )
        }

        source.breathingStartTask = task
        hostAudioSourcesByID[sourceID] = source
    }

    private func startEmergencyBroadcastLoop() {
        stopEmergencyBroadcastLoop()

        emergencyBroadcastTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(
                nanoseconds: UInt64(self.emergencyInitialDelaySeconds * 1_000_000_000)
            )

            while !Task.isCancelled {
                await self.playEmergencyBroadcastSequence()

                try? await Task.sleep(
                    nanoseconds: UInt64(self.emergencyBreakAfterBroadcastSeconds * 1_000_000_000)
                )
            }
        }
    }

    private func stopEmergencyBroadcastLoop() {
        emergencyBroadcastTask?.cancel()
        emergencyBroadcastTask = nil
    }

    private func playEmergencyBroadcastSequence() async {
        guard isDemoAudioActive else { return }

        guard let emergencyBeepResource,
              let emergencyBroadcastResource else {
            print("[Gravitas Audio] Emergency resources missing.")
            return
        }

        emergencyBeepController?.stop()
        emergencyBeepController = radioAudioEntity.playAudio(emergencyBeepResource)
        emergencyBeepController?.gain = Double(emergencyBeepDecibels)

        let beepDuration = durationSeconds(for: emergencyBeepFile)

        if beepDuration > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(beepDuration * 1_000_000_000)
            )
        }

        try? await Task.sleep(
            nanoseconds: UInt64(emergencyBeatDelaySeconds * 1_000_000_000)
        )

        guard isDemoAudioActive else { return }

        emergencyBroadcastController?.stop()
        emergencyBroadcastController = radioAudioEntity.playAudio(emergencyBroadcastResource)
        emergencyBroadcastController?.gain = decibels(linearVolume: 0.78)

        let broadcastDuration = durationSeconds(for: emergencyBroadcastFile)

        if broadcastDuration > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(broadcastDuration * 1_000_000_000)
            )
        }

        print("[Gravitas Audio] Spatial emergency sequence finished: beep completed -> beat -> broadcast completed.")
    }

    private func stopSpatialDemoControllers() {
        radioStaticController?.stop()
        radioStaticController = nil

        dadBreathingController?.stop()
        dadBreathingController = nil

        emergencyBeepController?.stop()
        emergencyBeepController = nil

        emergencyBroadcastController?.stop()
        emergencyBroadcastController = nil

        for controller in punchControllers {
            controller.stop()
        }
        punchControllers.removeAll()

        for id in Array(hostAudioSourcesByID.keys) {
            stopHostAudioSource(id: id)
        }
    }

    private func makePlayerDamagePlayers() -> [String: AVAudioPlayer] {
        var players: [String: AVAudioPlayer] = [:]

        for file in playerDamageFiles {
            do {
                let player = try makeAVAudioPlayer(
                    file: file,
                    volume: 0.90,
                    loopsForever: false
                )

                players[file.fileName] = player
            } catch {
                print("[Gravitas Audio] Warning: failed to load player damage sound \(file.fullName): \(error)")
            }
        }

        if players.isEmpty {
            print("[Gravitas Audio] Warning: no player damage sounds were loaded.")
        } else {
            print("[Gravitas Audio] Loaded \(players.count) player damage sounds.")
        }

        return players
    }

    private func makePlayerDeathPlayers() -> [String: AVAudioPlayer] {
        var players: [String: AVAudioPlayer] = [:]

        for file in playerDeathFiles {
            do {
                let player = try makeAVAudioPlayer(
                    file: file,
                    volume: 0.95,
                    loopsForever: false
                )

                players[file.fileName] = player
            } catch {
                print("[Gravitas Audio] Warning: failed to load player death sound \(file.fullName): \(error)")
            }
        }

        if players.isEmpty {
            print("[Gravitas Audio] Warning: no player death sounds were loaded.")
        } else {
            print("[Gravitas Audio] Loaded \(players.count) player death sounds.")
        }

        return players
    }

    private func stopPlayerDamagePlayers() {
        for player in playerDamagePlayersByFileName.values {
            player.stop()
            player.currentTime = 0
        }

        lastPlayerDamageFileName = nil
    }

    private func stopPlayerDeathPlayers() {
        for player in playerDeathPlayersByFileName.values {
            player.stop()
            player.currentTime = 0
        }

        lastPlayerDeathFileName = nil
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

    private func makeOptionalSpatialResource(
        file: BundleAudioFile,
        shouldLoop: Bool
    ) -> AudioFileResource? {
        do {
            return try loadSpatialResource(
                file: file,
                shouldLoop: shouldLoop
            )
        } catch {
            print("[Gravitas Audio] \(error)")
            return nil
        }
    }

    private func loadSpatialResource(
        file: BundleAudioFile,
        shouldLoop: Bool
    ) throws -> AudioFileResource {
        do {
            let configuration = AudioFileResource.Configuration(
                loadingStrategy: .preload,
                shouldLoop: shouldLoop
            )

            return try AudioFileResource.load(
                named: file.fullName,
                in: nil,
                configuration: configuration
            )
        } catch {
            throw AudioError.resourceLoadFailed(file.fullName, error)
        }
    }

    private func makeOptionalAVAudioPlayer(
        file: BundleAudioFile,
        volume: Float,
        loopsForever: Bool
    ) -> AVAudioPlayer? {
        do {
            return try makeAVAudioPlayer(
                file: file,
                volume: volume,
                loopsForever: loopsForever
            )
        } catch {
            print("[Gravitas Audio] \(error)")
            return nil
        }
    }

    private func makeAVAudioPlayer(
        file: BundleAudioFile,
        volume: Float,
        loopsForever: Bool
    ) throws -> AVAudioPlayer {
        guard let url = Bundle.main.url(
            forResource: file.fileName,
            withExtension: file.fileExtension
        ) else {
            throw AudioError.missingResource(file.fullName)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.numberOfLoops = loopsForever ? -1 : 0
            player.prepareToPlay()
            return player
        } catch {
            throw AudioError.playerCreationFailed(file.fullName, error)
        }
    }

    private func durationSeconds(for file: BundleAudioFile) -> TimeInterval {
        guard let url = Bundle.main.url(
            forResource: file.fileName,
            withExtension: file.fileExtension
        ) else {
            return 0
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            return 0
        }
    }

    private func decibels(linearVolume: Float) -> Double {
        guard linearVolume > 0 else {
            return -96.0
        }

        return Double(20.0 * log10(linearVolume))
    }
}
