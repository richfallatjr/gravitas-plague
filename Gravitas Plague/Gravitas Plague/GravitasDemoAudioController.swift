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

        init(
            fileName: String,
            fileExtension: String
        ) {
            self.fileName = fileName
            self.fileExtension = fileExtension
        }

        init(
            _ soundRef: SoundRef
        ) {
            self.fileName = soundRef.basename
            self.fileExtension = soundRef.ext
        }

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

        preloadCharacterAttributeAudio()

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

        print(
            """
            [PlagueAudio] attaching audio for character
              enemyID: \(id.uuidString)
              archetype: \(archetype.rawValue)
              source: character_attributes
            """
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
            volumeDB: Float(decibels(linearVolume: 0.95))
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

        let attributes: CharacterAttributes

        do {
            attributes = try CharacterAttributeStore.shared.attributes(
                for: archetype
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR face hit failed
                  archetype: \(archetype.rawValue)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        let sound: SoundRef

        do {
            sound = try attributes.audio.faceHits.weightedPickStrict(
                role: "face_hits",
                characterID: attributes.characterID
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR face hit failed
                  characterID: \(attributes.characterID)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        let file = BundleAudioFile(sound)

        guard validateAudioFileExistsForPlayback(
            sound,
            characterID: attributes.characterID,
            context: "face punch contact"
        ) else {
            return
        }

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print(
                """
                [CharacterAudio] ERROR missing face punch contact sound
                  characterID: \(attributes.characterID)
                  region: \(hitRegion.rawValue)
                  file: \(file.fullName)
                  noFallback: true
                """
            )
            return
        }

        playCharacterOneShot(
            resource: resource,
            sourceID: sourceID,
            volumeDB: sound.volumeDB ?? Float(decibels(linearVolume: 0.95))
        )

        print(
            """
            [CharacterAudio] one-shot played
              characterID: \(attributes.characterID)
              role: face_hits
              region: \(hitRegion.rawValue)
              file: \(sound.file)
              source: character_attributes
              noFallback: true
            """
        )
    }

    private func playCharacterDamagedSound(
        archetype: PlagueCharacterArchetype,
        sourceID: UUID?
    ) {
        let attributes: CharacterAttributes

        do {
            attributes = try CharacterAttributeStore.shared.attributes(
                for: archetype
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR damage hit failed
                  archetype: \(archetype.rawValue)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        let sound: SoundRef

        do {
            sound = try attributes.audio.damageHits.weightedPickStrict(
                role: "damage_hits",
                characterID: attributes.characterID
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR damage hit failed
                  characterID: \(attributes.characterID)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        let file = BundleAudioFile(sound)

        guard validateAudioFileExistsForPlayback(
            sound,
            characterID: attributes.characterID,
            context: "damage"
        ) else {
            return
        }

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print(
                """
                [CharacterAudio] ERROR missing damage sound
                  characterID: \(attributes.characterID)
                  file: \(file.fullName)
                  noFallback: true
                """
            )
            return
        }

        playCharacterOneShot(
            resource: resource,
            sourceID: sourceID,
            volumeDB: sound.volumeDB ?? Float(decibels(linearVolume: 0.88))
        )

        print(
            """
            [CharacterAudio] one-shot played
              characterID: \(attributes.characterID)
              role: damage_hits
              file: \(sound.file)
              source: character_attributes
              noFallback: true
            """
        )
    }

    private func validateAudioFileExistsForPlayback(
        _ sound: SoundRef,
        characterID: String,
        context: String
    ) -> Bool {
        if bundleURL(
            for: sound
        ) != nil {
            return true
        }

        print(
            """
            [CharacterAudio] ERROR missing \(context) sound
              characterID: \(characterID)
              file: \(sound.file)
              noFallback: true
            """
        )

        return false
    }

    private func bundleURL(
        for sound: SoundRef
    ) -> URL? {
        Bundle.main.url(
            forResource: sound.basename,
            withExtension: sound.ext
        ) ?? Bundle.main.url(
            forResource: sound.basename,
            withExtension: sound.ext,
            subdirectory: "Audio"
        )
    }

    private func playCharacterOneShot(
        resource: AudioFileResource,
        sourceID: UUID?,
        volumeDB: Float
    ) {
        if let sourceID,
           var source = hostAudioSourcesByID[sourceID] {
            let controller = source.headEntity.playAudio(resource)
            controller.gain = Double(volumeDB)
            source.punchControllers.append(controller)

            if source.punchControllers.count > 12 {
                source.punchControllers.removeFirst(max(0, source.punchControllers.count - 8))
            }

            hostAudioSourcesByID[sourceID] = source
            return
        }

        let controller = hostHeadAudioEntity.playAudio(resource)
        controller.gain = Double(volumeDB)
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
        let attributes: CharacterAttributes

        do {
            attributes = try CharacterAttributeStore.shared.attributes(
                for: archetype
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR presence loop failed
                  archetype: \(archetype.rawValue)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        guard let loop = attributes.audio.presenceLoop else {
            assertionFailure("Missing presence loop for \(attributes.characterID)")
            return
        }

        guard validateAudioFileExistsForPlayback(
            loop,
            characterID: attributes.characterID,
            context: "loop"
        ) else {
            return
        }

        let loopFile = BundleAudioFile(loop)

        guard let loopResource = spatialResource(
            for: loopFile,
            shouldLoop: true
        ) else {
            print(
                """
                [CharacterAudio] ERROR missing presence loop
                  characterID: \(attributes.characterID)
                  file: \(loopFile.fullName)
                  noFallback: true
                """
            )
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
            source.loopController?.gain = Double(loop.volumeDB ?? 0)
            source.loopStartTask = nil
            hostAudioSourcesByID[sourceID] = source

            print(
                """
                [CharacterAudio] presence loop attached
                  characterID: \(attributes.characterID)
                  file: \(loop.file)
                  source: character_attributes
                  noFallback: true
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
            source.loopController?.gain = Double(loop.volumeDB ?? 0)
            source.loopStartTask = nil
            self.hostAudioSourcesByID[sourceID] = source

            print(
                """
                [CharacterAudio] presence loop attached
                  characterID: \(attributes.characterID)
                  file: \(loop.file)
                  source: character_attributes
                  noFallback: true
                """
            )
        }

        source.loopStartTask = task
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

    private func preloadCharacterAttributeAudio() {
        do {
            if !CharacterAttributeStore.shared.isLoaded {
                try CharacterAttributeStore.shared.loadStrict()
            }
        } catch {
            print(
                """
                [CharacterAudio] ERROR strict character audio preload skipped
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        for attributes in CharacterAttributeStore.shared.attributesByID.values {
            if let loop = attributes.audio.presenceLoop {
                preloadSound(
                    named: loop.basename,
                    fileExtension: loop.ext,
                    shouldLoop: loop.loop ?? true,
                    category: "\(attributes.characterID)_presence_loop"
                )
            }

            for sound in attributes.audio.damageHits {
                preloadSound(
                    named: sound.basename,
                    fileExtension: sound.ext,
                    shouldLoop: false,
                    category: "\(attributes.characterID)_damage_hits"
                )
            }

            for sound in attributes.audio.faceHits {
                preloadSound(
                    named: sound.basename,
                    fileExtension: sound.ext,
                    shouldLoop: false,
                    category: "\(attributes.characterID)_face_hits"
                )
            }
        }

        print(
            """
            [CharacterAudio] attribute audio preloaded
              characters: \(CharacterAttributeStore.shared.attributesByID.keys.sorted().joined(separator: ", "))
              source: character_attributes
              noFallback: true
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
