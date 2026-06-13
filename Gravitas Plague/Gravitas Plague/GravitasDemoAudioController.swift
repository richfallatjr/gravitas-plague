import AVFoundation
import Foundation
import QuartzCore
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
        let archetype: PlagueCharacterArchetype
        var loopController: AudioPlaybackController?
        var loopStartTask: Task<Void, Never>?
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

    private let robotFacePunchFile = BundleAudioFile(
        fileName: PlagueAudioAssetName.fleshyFacePunch01,
        fileExtension: "wav"
    )

    private let robotWalkingLoopFile = BundleAudioFile(
        fileName: PlagueAudioAssetName.robotWalkingLoop,
        fileExtension: "mp3"
    )

    private let robotDamageFiles: [BundleAudioFile] = [
        BundleAudioFile(fileName: PlagueAudioAssetName.robotDamaged01, fileExtension: "wav"),
        BundleAudioFile(fileName: PlagueAudioAssetName.robotDamaged02, fileExtension: "wav")
    ]

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
    private var spatialResourcesByKey: [String: AudioFileResource] = [:]

    private var radioStaticController: AudioPlaybackController?
    private var dadBreathingController: AudioPlaybackController?
    private var emergencyBeepController: AudioPlaybackController?
    private var emergencyBroadcastController: AudioPlaybackController?
    private var punchControllers: [AudioPlaybackController] = []
    private var hostAudioSourcesByID: [UUID: HostAudioSource] = [:]
    private var lastCharacterHitSoundTimeByEnemyID: [UUID: TimeInterval] = [:]

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
    private let characterHitSoundCooldown: TimeInterval = 0.045

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

        dadBreathingResource = preloadSound(
            named: dadBreathingFile.fileName,
            fileExtension: dadBreathingFile.fileExtension,
            shouldLoop: true,
            category: "default_character_loop"
        )

        emergencyBeepResource = makeOptionalSpatialResource(
            file: emergencyBeepFile,
            shouldLoop: false
        )

        emergencyBroadcastResource = makeOptionalSpatialResource(
            file: emergencyBroadcastFile,
            shouldLoop: false
        )

        punchResource = preloadSound(
            named: punchFile.fileName,
            fileExtension: punchFile.fileExtension,
            shouldLoop: false,
            category: "default_face_hit"
        )

        preloadRobotAudio()

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
        archetype: PlagueCharacterArchetype = .dad,
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
            archetype: archetype,
            loopController: nil,
            loopStartTask: nil,
            punchControllers: []
        )

        startCharacterLoopAudio(
            sourceID: id,
            archetype: archetype,
            delay: breathingStartDelay
        )

        print(
            """
            [Gravitas Audio] Attached horde host audio source
              id: \(id)
              archetype: \(archetype.rawValue)
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

        source.loopStartTask?.cancel()
        source.loopStartTask = nil

        if source.loopController != nil {
            source.loopController?.stop()
            source.loopController = nil

            print(
                """
                [PlagueAudio] character loop stopped
                  archetype: \(source.archetype.rawValue)
                  enemyID: \(id.uuidString)
                """
            )
        }

        for controller in source.punchControllers {
            controller.stop()
        }
        source.punchControllers.removeAll()

        source.headEntity.removeFromParent()
        lastCharacterHitSoundTimeByEnemyID.removeValue(forKey: id)

        print("[Gravitas Audio] Stopped horde host audio source: \(id)")
    }

    func stopCharacterLoopAudio(
        id: UUID
    ) {
        guard var source = hostAudioSourcesByID[id] else {
            return
        }

        source.loopStartTask?.cancel()
        source.loopStartTask = nil

        source.loopController?.stop()
        source.loopController = nil

        hostAudioSourcesByID[id] = source

        print(
            """
            [PlagueAudio] character loop stopped
              archetype: \(source.archetype.rawValue)
              enemyID: \(id.uuidString)
            """
        )
    }

    func stopHostDadBreathing(
        id: UUID
    ) {
        stopCharacterLoopAudio(
            id: id
        )
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

        playCharacterOneShot(
            resource: punchResource,
            sourceID: sourceID,
            linearVolume: 0.95
        )
    }

    func playConfirmedCharacterHitSounds(
        archetype: PlagueCharacterArchetype,
        enemyID: UUID?,
        hitRegion: InfectedHitRegion,
        sourceID: UUID? = nil
    ) {
        prepareIfNeeded()

        if let enemyID {
            let now = CACurrentMediaTime()
            let last = lastCharacterHitSoundTimeByEnemyID[enemyID] ?? 0

            guard now - last >= characterHitSoundCooldown else {
                return
            }

            lastCharacterHitSoundTimeByEnemyID[enemyID] = now
        }

        playFacePunchContactSoundIfNeeded(
            archetype: archetype,
            hitRegion: hitRegion,
            sourceID: sourceID
        )

        playCharacterDamagedSound(
            archetype: archetype,
            sourceID: sourceID
        )
    }

    private func playFacePunchContactSoundIfNeeded(
        archetype: PlagueCharacterArchetype,
        hitRegion: InfectedHitRegion,
        sourceID: UUID?
    ) {
        guard hitRegion == .head else {
            return
        }

        let profile = archetype.audioProfile

        guard let sound = profile.facePunchContactSounds.randomElement() else {
            return
        }

        let file = BundleAudioFile(
            fileName: sound,
            fileExtension: profile.facePunchContactExtension
        )

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print("[PlagueAudio] WARNING missing face punch sound \(file.fullName)")
            return
        }

        playCharacterOneShot(
            resource: resource,
            sourceID: sourceID,
            linearVolume: 0.95
        )

        print(
            """
            [PlagueAudio] face punch contact sound played
              archetype: \(archetype.rawValue)
              region: \(hitRegion.rawValue)
              sound: \(file.fullName)
            """
        )
    }

    private func playCharacterDamagedSound(
        archetype: PlagueCharacterArchetype,
        sourceID: UUID?
    ) {
        let profile = archetype.audioProfile

        guard let sound = profile.damagedSounds.randomElement() else {
            return
        }

        let file = BundleAudioFile(
            fileName: sound,
            fileExtension: profile.damagedSoundExtension
        )

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print("[PlagueAudio] WARNING missing damaged sound \(file.fullName)")
            return
        }

        playCharacterOneShot(
            resource: resource,
            sourceID: sourceID,
            linearVolume: 0.88
        )

        print(
            """
            [PlagueAudio] damaged sound played
              archetype: \(archetype.rawValue)
              sound: \(file.fullName)
            """
        )
    }

    private func playCharacterOneShot(
        resource: AudioFileResource,
        sourceID: UUID?,
        linearVolume: Float
    ) {
        if let sourceID,
           var source = hostAudioSourcesByID[sourceID] {
            let controller = source.headEntity.playAudio(resource)
            controller.gain = decibels(linearVolume: linearVolume)
            source.punchControllers.append(controller)

            if source.punchControllers.count > 12 {
                source.punchControllers.removeFirst(max(0, source.punchControllers.count - 8))
            }

            hostAudioSourcesByID[sourceID] = source
            return
        }

        let controller = hostHeadAudioEntity.playAudio(resource)
        controller.gain = decibels(linearVolume: linearVolume)
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

    private func startCharacterLoopAudio(
        sourceID: UUID,
        archetype: PlagueCharacterArchetype,
        delay: TimeInterval
    ) {
        let profile = archetype.audioProfile

        guard let loopName = profile.breathingOrMovementLoop,
              let loopExtension = profile.breathingOrMovementLoopExtension else {
            return
        }

        let loopFile = BundleAudioFile(
            fileName: loopName,
            fileExtension: loopExtension
        )

        guard let loopResource = spatialResource(
            for: loopFile,
            shouldLoop: true
        ) else {
            print("[PlagueAudio] WARNING missing character loop \(loopFile.fullName)")
            return
        }

        guard var source = hostAudioSourcesByID[sourceID] else {
            print("[PlagueAudio] Missing horde host audio source for character loop: \(sourceID)")
            return
        }

        source.loopStartTask?.cancel()
        source.loopController?.stop()

        if delay <= 0 {
            source.loopController = source.headEntity.playAudio(loopResource)
            source.loopController?.gain = decibels(linearVolume: characterLoopGain(for: archetype))
            source.loopStartTask = nil
            hostAudioSourcesByID[sourceID] = source

            print(
                """
                [PlagueAudio] character loop attached
                  archetype: \(archetype.rawValue)
                  sound: \(loopFile.fullName)
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
                  var source = self.hostAudioSourcesByID[sourceID] else {
                return
            }

            source.loopController?.stop()
            source.loopController = source.headEntity.playAudio(loopResource)
            source.loopController?.gain = self.decibels(linearVolume: self.characterLoopGain(for: archetype))
            source.loopStartTask = nil
            self.hostAudioSourcesByID[sourceID] = source

            print(
                """
                [PlagueAudio] character loop attached
                  archetype: \(archetype.rawValue)
                  sound: \(loopFile.fullName)
                """
            )
        }

        source.loopStartTask = task
        hostAudioSourcesByID[sourceID] = source
    }

    private func characterLoopGain(
        for archetype: PlagueCharacterArchetype
    ) -> Float {
        switch archetype {
        case .robot:
            return 0.48

        case .dad, .spouse, .biker, .grandma, .neighbor:
            return 0.42
        }
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

    @discardableResult
    private func preloadSound(
        named fileName: String,
        fileExtension: String,
        shouldLoop: Bool = false,
        category: String
    ) -> AudioFileResource? {
        let file = BundleAudioFile(
            fileName: fileName,
            fileExtension: fileExtension
        )

        let key = spatialResourceKey(
            file: file,
            shouldLoop: shouldLoop
        )

        if let resource = spatialResourcesByKey[key] {
            return resource
        }

        guard let resource = makeOptionalSpatialResource(
            file: file,
            shouldLoop: shouldLoop
        ) else {
            print(
                """
                [PlagueAudio] WARNING failed to preload sound
                  category: \(category)
                  file: \(file.fullName)
                """
            )
            return nil
        }

        spatialResourcesByKey[key] = resource
        return resource
    }

    private func preloadRobotAudio() {
        preloadSound(
            named: robotFacePunchFile.fileName,
            fileExtension: robotFacePunchFile.fileExtension,
            shouldLoop: false,
            category: "robot_face_hit"
        )

        preloadSound(
            named: robotWalkingLoopFile.fileName,
            fileExtension: robotWalkingLoopFile.fileExtension,
            shouldLoop: true,
            category: "robot_loop"
        )

        for file in robotDamageFiles {
            preloadSound(
                named: file.fileName,
                fileExtension: file.fileExtension,
                shouldLoop: false,
                category: "robot_damage"
            )
        }

        print(
            """
            [PlagueAudio] robot audio preloaded
              faceHit: fleshy-face-punch-01.wav
              loop: robot-walking-loop.mp3
              damaged: robot-damaged-01.wav, robot-damaged-02.wav
            """
        )
    }

    private func spatialResource(
        for file: BundleAudioFile,
        shouldLoop: Bool
    ) -> AudioFileResource? {
        let key = spatialResourceKey(
            file: file,
            shouldLoop: shouldLoop
        )

        if let resource = spatialResourcesByKey[key] {
            return resource
        }

        return preloadSound(
            named: file.fileName,
            fileExtension: file.fileExtension,
            shouldLoop: shouldLoop,
            category: "lazy_character_audio"
        )
    }

    private func spatialResourceKey(
        file: BundleAudioFile,
        shouldLoop: Bool
    ) -> String {
        "\(file.fullName)|loop:\(shouldLoop)"
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

            do {
                return try AudioFileResource.load(
                    named: file.fullName,
                    in: nil,
                    configuration: configuration
                )
            } catch {
                return try AudioFileResource.load(
                    named: "Audio/\(file.fullName)",
                    in: nil,
                    configuration: configuration
                )
            }
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
        guard let url = bundleURL(for: file) else {
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
        guard let url = bundleURL(for: file) else {
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

    private func bundleURL(
        for file: BundleAudioFile
    ) -> URL? {
        Bundle.main.url(
            forResource: file.fileName,
            withExtension: file.fileExtension
        ) ?? Bundle.main.url(
            forResource: file.fileName,
            withExtension: file.fileExtension,
            subdirectory: "Audio"
        )
    }
}
