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
        let usesResolvedHeadAnchor: Bool
        var loopController: AudioPlaybackController?
        var loopStartTask: Task<Void, Never>?
    }

    private struct ActiveSpatialOneShot {
        let id: UUID
        let label: String
        let file: String
        let startedAt: TimeInterval
        let expectedEndTime: TimeInterval
        let emitterName: String
        let playbackController: AudioPlaybackController
    }

    private struct ActiveCharacterVocal {
        let id: UUID
        let sourceID: UUID
        let characterID: String
        let role: String
        let file: String
        let startedAt: TimeInterval
        let expectedEndTime: TimeInterval
        let playbackController: AudioPlaybackController
    }

    private let backgroundMusicFile = BundleAudioFile(
        fileName: "GravitasPlagueBackgroundLoop",
        fileExtension: "wav"
    )

    private let hordeMusicBoxFile = BundleAudioFile(
        fileName: "music-box",
        fileExtension: "mp3"
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

    private let satanActedFile = BundleAudioFile(
        fileName: "satan-acted",
        fileExtension: "mp3"
    )

    private let satanLatinFile = BundleAudioFile(
        fileName: "satan-latin",
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
    private var hordeMusicBoxPlayer: AVAudioPlayer?
    private var hordeMusicCurrentSongPlayer: AVAudioPlayer?
    private var hordeMusicSequenceTask: Task<Void, Never>?
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
    private var satanActedResource: AudioFileResource?
    private var satanLatinResource: AudioFileResource?
    private var spatialResourcesByKey: [String: AudioFileResource] = [:]

    private var radioStaticController: AudioPlaybackController?
    private var dadBreathingController: AudioPlaybackController?
    private var emergencyBeepController: AudioPlaybackController?
    private var emergencyBroadcastController: AudioPlaybackController?
    private var satanActedController: AudioPlaybackController?
    private var satanLatinController: AudioPlaybackController?
    private var portalOneShotControllers: [AudioPlaybackController] = []
    private var hostAudioSourcesByID: [UUID: HostAudioSource] = [:]
    private var activeSpatialOneShotsByID: [UUID: ActiveSpatialOneShot] = [:]
    private var activeCharacterVocalBySourceID: [UUID: ActiveCharacterVocal] = [:]

    private var emergencyBroadcastTask: Task<Void, Never>?

    private var hasPrepared = false
    private var hasAttachedEntities = false
    private var hasAttachedRadioEntity = false
    private var hasAttachedHostHeadEntity = false
    private var isImmersiveAudioActive = false
    private var isDemoAudioActive = false

    private let feetToMeters: Float = 0.3048

    var activeSpatialOneShotCountForProfiling: Int {
        activeSpatialOneShotsByID.count +
            portalOneShotControllers.count +
            activeCharacterVocalBySourceID.count
    }
    private let radioDistanceBehindUserFeet: Float = 5.0
    private let hostHeadAudioLocalPosition = SIMD3<Float>(0, 1.45, -0.04)
    private let maxActiveSpatialOneShots = 96

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

        hordeMusicBoxPlayer = makeOptionalAVAudioPlayer(
            file: hordeMusicBoxFile,
            volume: 0.30,
            loopsForever: false
        )

        hordeMusicCurrentSongPlayer = makeOptionalAVAudioPlayer(
            file: backgroundMusicFile,
            volume: 0.30,
            loopsForever: false
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

        satanActedResource = makeOptionalSpatialResource(
            file: satanActedFile,
            shouldLoop: false
        )

        satanLatinResource = makeOptionalSpatialResource(
            file: satanLatinFile,
            shouldLoop: false
        )

        preloadSound(
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
        headAudioEntity: Entity?,
        breathingStartDelay: TimeInterval = TimeInterval.random(in: 0...1)
    ) {
        prepareIfNeeded()
        stopHostAudioSource(id: id)

        let headEntity: Entity
        let usesResolvedHeadAnchor: Bool

        if let headAudioEntity {
            headEntity = headAudioEntity
            usesResolvedHeadAnchor = true
        } else {
            print(
                """
                [CharacterAudio] ERROR missing head audio emitter
                  enemyID: \(id.uuidString)
                  archetype: \(archetype.rawValue)
                  requiredFor: damage_death_spatial_audio
                  noFallback: true
                """
            )

            let fallbackEntity = Entity()
            fallbackEntity.name = "Gravitas_HordeHostPresenceAudioSource_\(id.uuidString.prefix(6))"
            fallbackEntity.position = hostHeadAudioLocalPosition
            hostRootEntity.addChild(fallbackEntity)

            headEntity = fallbackEntity
            usesResolvedHeadAnchor = false
        }

        headEntity.components.set(SpatialAudioComponent())

        hostAudioSourcesByID[id] = HostAudioSource(
            headEntity: headEntity,
            archetype: archetype,
            usesResolvedHeadAnchor: usesResolvedHeadAnchor,
            loopController: nil,
            loopStartTask: nil
        )

        print(
            """
            [PlagueAudio] attaching audio for character
              enemyID: \(id.uuidString)
              archetype: \(archetype.rawValue)
              source: character_attributes
              emitter: head
              resolvedHeadAnchor: \(usesResolvedHeadAnchor)
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
              parent: \(usesResolvedHeadAnchor ? "characterAudioEmitter" : "legacyPresenceOffset")
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

        if let vocal = activeCharacterVocalBySourceID.removeValue(
            forKey: id
        ) {
            vocal.playbackController.stop()

            print(
                """
                [CharacterAudio] stopped character vocal for source cleanup
                  channel: characterVocal
                  policy: replacePerSource
                  sourceID: \(id.uuidString)
                  characterID: \(vocal.characterID)
                  role: \(vocal.role)
                  file: \(vocal.file)
                """
            )
        }

        if !source.usesResolvedHeadAnchor {
            source.headEntity.removeFromParent()
        }

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

    @discardableResult
    func attachSpatialLoop(
        named name: String,
        fileExtension ext: String,
        to entity: Entity,
        volumeDB: Float,
        label: String
    ) -> AudioPlaybackController? {
        prepareIfNeeded()

        let file = BundleAudioFile(
            fileName: name,
            fileExtension: ext
        )

        guard bundleURL(for: file) != nil else {
            print(
                """
                [Gravitas Audio] ERROR missing spatial loop
                  file: \(file.fullName)
                  label: \(label)
                  fallback: false
                """
            )
            return nil
        }

        guard let resource = spatialResource(
            for: file,
            shouldLoop: true
        ) else {
            print(
                """
                [Gravitas Audio] ERROR failed to load spatial loop
                  file: \(file.fullName)
                  label: \(label)
                  fallback: false
                """
            )
            return nil
        }

        entity.components.set(SpatialAudioComponent())

        let controller = entity.playAudio(resource)
        controller.gain = Double(volumeDB)

        print(
            """
            [Gravitas Audio] spatial loop attached
              file: \(file.fullName)
              label: \(label)
              gainDB: \(volumeDB)
              spatial: true
              loop: true
            """
        )

        return controller
    }

    @discardableResult
    func playSpatialOneShot(
        named name: String,
        fileExtension ext: String,
        at entity: Entity,
        volumeDB: Float,
        label: String
    ) -> Bool {
        prepareIfNeeded()

        if isForbiddenCharacterOneShotLabel(label) {
            print(
                """
                [Gravitas Audio] ERROR blocked forbidden global character sound
                  file: \(name).\(ext)
                  label: \(label)
                  routeRequired: concurrent_spatial_head
                """
            )
            return false
        }

        let file = BundleAudioFile(
            fileName: name,
            fileExtension: ext
        )

        guard bundleURL(for: file) != nil else {
            print(
                """
                [Gravitas Audio] ERROR missing spatial one-shot
                  file: \(file.fullName)
                  label: \(label)
                  fallback: false
                """
            )
            return false
        }

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print(
                """
                [Gravitas Audio] ERROR failed to load spatial one-shot
                  file: \(file.fullName)
                  label: \(label)
                  fallback: false
                """
            )
            return false
        }

        entity.components.set(SpatialAudioComponent())

        let controller = entity.playAudio(resource)
        controller.gain = Double(volumeDB)
        portalOneShotControllers.append(controller)

        if portalOneShotControllers.count > 16 {
            portalOneShotControllers.removeFirst(
                max(0, portalOneShotControllers.count - 12)
            )
        }

        print(
            """
            [Gravitas Audio] spatial one-shot played
              file: \(file.fullName)
              label: \(label)
              gainDB: \(volumeDB)
              spatial: true
              loop: false
            """
        )

        return true
    }

    @discardableResult
    func playConcurrentSpatialOneShot(
        named name: String,
        fileExtension ext: String,
        at entity: Entity,
        volumeDB: Float,
        label: String
    ) -> UUID? {
        let file = BundleAudioFile(
            fileName: name,
            fileExtension: ext
        )

        return playConcurrentSpatialOneShot(
            file: file,
            at: entity,
            volumeDB: volumeDB,
            label: label
        )
    }

    func setLoopGainDB(
        _ controller: AudioPlaybackController,
        gainDB: Float
    ) {
        controller.gain = Double(gainDB)
    }

    func stopLoop(
        _ controller: AudioPlaybackController
    ) {
        controller.stop()
    }

    func startHordeMusicSequence() {
        stopHordeMusicSequence()

        backgroundMusicPlayer?.stop()
        backgroundMusicPlayer?.currentTime = 0

        guard let musicBoxPlayer = hordeMusicBoxPlayer,
              let currentSongPlayer = hordeMusicCurrentSongPlayer else {
            print("[Gravitas Audio] ERROR cannot start Horde music sequence; missing music player")
            return
        }

        hordeMusicSequenceTask = Task { @MainActor in
            print("[Gravitas Audio] Started Horde music sequence: music-box -> background loop")

            while !Task.isCancelled {
                await playHordeMusicTrack(
                    player: musicBoxPlayer,
                    file: hordeMusicBoxFile
                )

                guard !Task.isCancelled else { break }

                await playHordeMusicTrack(
                    player: currentSongPlayer,
                    file: backgroundMusicFile
                )
            }
        }
    }

    func stopHordeMusicSequence() {
        hordeMusicSequenceTask?.cancel()
        hordeMusicSequenceTask = nil

        hordeMusicBoxPlayer?.stop()
        hordeMusicBoxPlayer?.currentTime = 0

        hordeMusicCurrentSongPlayer?.stop()
        hordeMusicCurrentSongPlayer?.currentTime = 0
    }

    private func playHordeMusicTrack(
        player: AVAudioPlayer,
        file: BundleAudioFile
    ) async {
        guard !Task.isCancelled else { return }

        player.stop()
        player.currentTime = 0
        player.numberOfLoops = 0
        player.play()

        let duration = player.duration > 0
            ? player.duration
            : durationSeconds(for: file)

        guard duration > 0 else {
            return
        }

        try? await Task.sleep(
            nanoseconds: UInt64(duration * 1_000_000_000)
        )

        player.stop()
        player.currentTime = 0
    }

    func startImmersiveAudio() {
        prepareIfNeeded()

        guard !isImmersiveAudioActive else { return }

        isImmersiveAudioActive = true

        if hordeMusicSequenceTask == nil {
            backgroundMusicPlayer?.currentTime = 0
            backgroundMusicPlayer?.play()
        }

        print("[Gravitas Audio] Started global background music.")
    }

    func startDemoAudio(
        spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        prepareIfNeeded()

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
        stopHordeMusicSequence()

        backgroundMusicPlayer?.stop()
        backgroundMusicPlayer?.currentTime = 0

        stopSpatialDemoControllers()
        stopPlayerDamagePlayers()
        stopPlayerDeathPlayers()
        stopPortalOneShotControllers()
        stopActiveSpatialOneShots()
        stopActiveCharacterVocals()

        print("[Gravitas Audio] Stopped all audio.")
    }

    func playPunchHitAtHostHead(
        sourceID: UUID? = nil
    ) {
        prepareIfNeeded()

        _ = playConcurrentCharacterSpatialOneShot(
            file: punchFile,
            characterID: "host",
            role: "face_hits",
            sourceID: sourceID,
            volumeDB: Float(decibels(linearVolume: 0.95))
        )
    }

    func playConfirmedCharacterFaceHitSound(
        archetype: PlagueCharacterArchetype,
        enemyID: UUID?,
        hitRegion: InfectedHitRegion,
        sourceID: UUID? = nil
    ) {
        prepareIfNeeded()
        _ = enemyID

        playFacePunchContactSoundIfNeeded(
            archetype: archetype,
            hitRegion: hitRegion,
            sourceID: sourceID
        )
    }

    func playCharacterDamageHit(
        archetype: PlagueCharacterArchetype,
        enemyID: UUID,
        sourceID: UUID
    ) {
        _ = enemyID
        prepareIfNeeded()

        playCharacterAudioBankReplacingVocal(
            archetype: archetype,
            sourceID: sourceID,
            role: "damage_hits",
            refs: { $0.audio.damageHits },
            fallbackVolumeDB: Float(decibels(linearVolume: 0.88))
        )
    }

    func playCharacterDeath(
        archetype: PlagueCharacterArchetype,
        enemyID: UUID,
        sourceID: UUID
    ) {
        _ = enemyID
        prepareIfNeeded()

        playCharacterAudioBankReplacingVocal(
            archetype: archetype,
            sourceID: sourceID,
            role: "death",
            refs: { $0.audio.death },
            fallbackVolumeDB: 0
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

        _ = playConcurrentCharacterSpatialOneShot(
            file: file,
            characterID: attributes.characterID,
            role: "face_hits",
            sourceID: sourceID,
            volumeDB: sound.volumeDB ?? Float(decibels(linearVolume: 0.95))
        )
    }

    private func playCharacterAudioBankReplacingVocal(
        archetype: PlagueCharacterArchetype,
        sourceID: UUID,
        role: String,
        refs: (CharacterAttributes) -> [SoundRef],
        fallbackVolumeDB: Float
    ) {
        let attributes: CharacterAttributes

        do {
            attributes = try CharacterAttributeStore.shared.attributes(
                for: archetype
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR \(role) failed
                  archetype: \(archetype.rawValue)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )
            return
        }

        let sound: SoundRef

        do {
            let bank = refs(attributes)

            sound = try bank.weightedPickStrict(
                role: role,
                characterID: attributes.characterID
            )

            print(
                """
                [CharacterAudio] random bank selected
                  characterID: \(attributes.characterID)
                  role: \(role)
                  bankSize: \(bank.count)
                  selected: \(sound.file)
                """
            )
        } catch {
            print(
                """
                [CharacterAudio] ERROR \(role) failed
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
            context: role
        ) else {
            return
        }

        _ = playReplacingCharacterVocal(
            file: file,
            characterID: attributes.characterID,
            role: role,
            sourceID: sourceID,
            volumeDB: sound.volumeDB ?? fallbackVolumeDB
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
              let satanActedResource,
              let satanLatinResource,
              let emergencyBroadcastResource else {
            print("[Gravitas Audio] Emergency resources missing.")
            return
        }

        await playRadioBroadcastClip(
            resource: satanActedResource,
            file: satanActedFile,
            controller: \.satanActedController,
            volume: 0.78
        )

        await sleepEmergencyBreakIfActive()

        await playRadioBroadcastClip(
            resource: satanLatinResource,
            file: satanLatinFile,
            controller: \.satanLatinController,
            volume: 0.78
        )

        await sleepEmergencyBreakIfActive()

        await playEmergencyBeep(
            resource: emergencyBeepResource
        )

        await sleepEmergencyBeatIfActive()

        await playRadioBroadcastClip(
            resource: emergencyBroadcastResource,
            file: emergencyBroadcastFile,
            controller: \.emergencyBroadcastController,
            volume: 0.78
        )

        print("[Gravitas Audio] Spatial emergency sequence finished: satan acted -> satan latin -> beep -> broadcast.")
    }

    private func playEmergencyBeep(
        resource: AudioFileResource
    ) async {
        guard isDemoAudioActive else { return }

        emergencyBeepController?.stop()
        emergencyBeepController = radioAudioEntity.playAudio(resource)
        emergencyBeepController?.gain = Double(emergencyBeepDecibels)

        let duration = durationSeconds(for: emergencyBeepFile)

        if duration > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(duration * 1_000_000_000)
            )
        }
    }

    private func playRadioBroadcastClip(
        resource: AudioFileResource,
        file: BundleAudioFile,
        controller: ReferenceWritableKeyPath<GravitasDemoAudioController, AudioPlaybackController?>,
        volume: Float
    ) async {
        guard isDemoAudioActive else { return }

        self[keyPath: controller]?.stop()
        self[keyPath: controller] = radioAudioEntity.playAudio(resource)
        self[keyPath: controller]?.gain = decibels(linearVolume: volume)

        let duration = durationSeconds(for: file)

        if duration > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(duration * 1_000_000_000)
            )
        }
    }

    private func sleepEmergencyBeatIfActive() async {
        guard isDemoAudioActive else { return }

        try? await Task.sleep(
            nanoseconds: UInt64(emergencyBeatDelaySeconds * 1_000_000_000)
        )
    }

    private func sleepEmergencyBreakIfActive() async {
        guard isDemoAudioActive else { return }

        try? await Task.sleep(
            nanoseconds: UInt64(emergencyBreakAfterBroadcastSeconds * 1_000_000_000)
        )
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

        satanActedController?.stop()
        satanActedController = nil

        satanLatinController?.stop()
        satanLatinController = nil

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

    private func stopPortalOneShotControllers() {
        for controller in portalOneShotControllers {
            controller.stop()
        }

        portalOneShotControllers.removeAll()
    }

    private func stopActiveSpatialOneShots() {
        for oneShot in activeSpatialOneShotsByID.values {
            oneShot.playbackController.stop()
        }

        if !activeSpatialOneShotsByID.isEmpty {
            print(
                """
                [Gravitas Audio] stopped active concurrent spatial one-shots
                  stopped: \(activeSpatialOneShotsByID.count)
                """
            )
        }

        activeSpatialOneShotsByID.removeAll()
    }

    private func stopActiveCharacterVocals() {
        for vocal in activeCharacterVocalBySourceID.values {
            vocal.playbackController.stop()
        }

        if !activeCharacterVocalBySourceID.isEmpty {
            print(
                """
                [CharacterAudio] stopped active character vocals
                  channel: characterVocal
                  stopped: \(activeCharacterVocalBySourceID.count)
                """
            )
        }

        activeCharacterVocalBySourceID.removeAll()
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

            for sound in attributes.audio.death {
                preloadSound(
                    named: sound.basename,
                    fileExtension: sound.ext,
                    shouldLoop: false,
                    category: "\(attributes.characterID)_death"
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

    private func isForbiddenCharacterOneShotLabel(
        _ label: String
    ) -> Bool {
        label.contains("_damage") ||
        label.contains("_death") ||
        label.contains("damage_hits") ||
        label.contains("face_hits")
    }

    @discardableResult
    private func playConcurrentSpatialOneShot(
        file: BundleAudioFile,
        at entity: Entity,
        volumeDB: Float,
        label: String
    ) -> UUID? {
        prepareIfNeeded()

        guard bundleURL(for: file) != nil else {
            print(
                """
                [Gravitas Audio] ERROR missing concurrent spatial one-shot
                  file: \(file.fullName)
                  label: \(label)
                  fallback: false
                """
            )
            return nil
        }

        guard entity.parent != nil else {
            print(
                """
                [Gravitas Audio] ERROR spatial one-shot emitter is not in scene
                  file: \(file.fullName)
                  label: \(label)
                  emitter: \(entity.name)
                  fallback: false
                """
            )
            return nil
        }

        pruneFinishedSpatialOneShots()

        if activeSpatialOneShotsByID.count >= maxActiveSpatialOneShots {
            pruneOldestSpatialOneShot()

            print(
                """
                [Gravitas Audio] WARNING active one-shot limit reached; pruned oldest
                  maxActive: \(maxActiveSpatialOneShots)
                  label: \(label)
                """
            )
        }

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print(
                """
                [Gravitas Audio] ERROR failed loading concurrent spatial one-shot
                  file: \(file.fullName)
                  label: \(label)
                  fallback: false
                """
            )
            return nil
        }

        entity.components.set(SpatialAudioComponent())

        let controller = entity.playAudio(resource)
        controller.gain = Double(volumeDB)

        print(
            """
            [Gravitas Audio] spatial playback controller configured
              label: \(label)
              requestedVolumeDB: \(volumeDB)
              appliedGainMode: controller.gain
              appliedGainValue: \(controller.gain)
              spatial: true
              attachedEmitter: \(entity.name)
            """
        )

        let id = UUID()
        let now = CACurrentMediaTime()
        let duration = estimatedDurationSeconds(
            for: file,
            fallback: 3.0
        )

        activeSpatialOneShotsByID[id] = ActiveSpatialOneShot(
            id: id,
            label: label,
            file: file.fullName,
            startedAt: now,
            expectedEndTime: now + duration + 0.25,
            emitterName: entity.name,
            playbackController: controller
        )

        print(
            """
            [Gravitas Audio] concurrent spatial one-shot started
              id: \(id)
              file: \(file.fullName)
              label: \(label)
              emitter: \(entity.name)
              volumeDB: \(volumeDB)
              activeOneShots: \(activeSpatialOneShotsByID.count)
              replacesExisting: false
              spatial: true
              global: false
            """
        )

        return id
    }

    @discardableResult
    private func playConcurrentCharacterSpatialOneShot(
        file: BundleAudioFile,
        characterID: String,
        role: String,
        sourceID: UUID?,
        volumeDB: Float
    ) -> UUID? {
        guard let sourceID else {
            print(
                """
                [CharacterAudio] ERROR missing head audio emitter
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  noFallback: true
                  noRootFallback: true
                  global: false
                """
            )
            return nil
        }

        guard let source = hostAudioSourcesByID[sourceID] else {
            print(
                """
                [CharacterAudio] ERROR missing head audio emitter
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  enemyID: \(sourceID.uuidString)
                  noFallback: true
                  noRootFallback: true
                  global: false
                """
            )
            return nil
        }

        guard source.usesResolvedHeadAnchor else {
            print(
                """
                [CharacterAudio] ERROR head audio anchor unresolved
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  enemyID: \(sourceID.uuidString)
                  noFallback: true
                  noRootFallback: true
                  global: false
                """
            )
            return nil
        }

        let id = playConcurrentSpatialOneShot(
            file: file,
            at: source.headEntity,
            volumeDB: volumeDB,
            label: "\(characterID)_\(role)"
        )

        print(
            """
            [CharacterAudio] one-shot requested
              id: \(id?.uuidString ?? "nil")
              channel: impact
              policy: concurrent
              sourceID: \(sourceID.uuidString)
              characterID: \(characterID)
              role: \(role)
              file: \(file.fullName)
              emitter: head
              emitterName: \(source.headEntity.name)
              volumeDB: \(volumeDB)
              spatial: true
              global: false
              concurrent: true
              source: character_attributes
              noFallback: true
            """
        )

        return id
    }

    @discardableResult
    private func playReplacingCharacterVocal(
        file: BundleAudioFile,
        characterID: String,
        role: String,
        sourceID: UUID,
        volumeDB: Float
    ) -> UUID? {
        prepareIfNeeded()

        guard let source = hostAudioSourcesByID[sourceID] else {
            print(
                """
                [CharacterAudio] ERROR missing head audio emitter
                  channel: characterVocal
                  policy: replacePerSource
                  sourceID: \(sourceID.uuidString)
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  noFallback: true
                  global: false
                """
            )
            return nil
        }

        guard source.usesResolvedHeadAnchor else {
            print(
                """
                [CharacterAudio] ERROR head audio anchor unresolved
                  channel: characterVocal
                  policy: replacePerSource
                  sourceID: \(sourceID.uuidString)
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  noFallback: true
                  global: false
                """
            )
            return nil
        }

        guard source.headEntity.parent != nil else {
            print(
                """
                [CharacterAudio] ERROR character vocal emitter is not in scene
                  channel: characterVocal
                  policy: replacePerSource
                  sourceID: \(sourceID.uuidString)
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  emitter: \(source.headEntity.name)
                  fallback: false
                """
            )
            return nil
        }

        guard bundleURL(for: file) != nil else {
            print(
                """
                [CharacterAudio] ERROR missing character vocal
                  channel: characterVocal
                  policy: replacePerSource
                  sourceID: \(sourceID.uuidString)
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  fallback: false
                """
            )
            return nil
        }

        pruneFinishedCharacterVocals()

        guard let resource = spatialResource(
            for: file,
            shouldLoop: false
        ) else {
            print(
                """
                [CharacterAudio] ERROR failed loading character vocal
                  channel: characterVocal
                  policy: replacePerSource
                  sourceID: \(sourceID.uuidString)
                  characterID: \(characterID)
                  role: \(role)
                  file: \(file.fullName)
                  fallback: false
                """
            )
            return nil
        }

        let previous = activeCharacterVocalBySourceID.removeValue(
            forKey: sourceID
        )

        previous?.playbackController.stop()

        let controller = source.headEntity.playAudio(resource)
        controller.gain = Double(volumeDB)

        let id = UUID()
        let now = CACurrentMediaTime()
        let duration = estimatedDurationSeconds(
            for: file,
            fallback: 3.0
        )

        activeCharacterVocalBySourceID[sourceID] = ActiveCharacterVocal(
            id: id,
            sourceID: sourceID,
            characterID: characterID,
            role: role,
            file: file.fullName,
            startedAt: now,
            expectedEndTime: now + duration + 0.25,
            playbackController: controller
        )

        print(
            """
            [CharacterAudio] replacing vocal started
              channel: characterVocal
              policy: replacePerSource
              sourceID: \(sourceID.uuidString)
              characterID: \(characterID)
              role: \(role)
              file: \(file.fullName)
              replacedExisting: \(previous != nil)
              previousRole: \(previous?.role ?? "none")
              previousFile: \(previous?.file ?? "none")
              activeCharacterVocals: \(activeCharacterVocalBySourceID.count)
              multiCharacterLayeringAllowed: true
            """
        )

        return id
    }

    private func pruneFinishedSpatialOneShots() {
        pruneFinishedCharacterVocals()

        let now = CACurrentMediaTime()
        let expired = activeSpatialOneShotsByID.values.filter {
            $0.expectedEndTime <= now
        }

        for oneShot in expired {
            activeSpatialOneShotsByID.removeValue(
                forKey: oneShot.id
            )
        }

        if !expired.isEmpty {
            print(
                """
                [Gravitas Audio] pruned finished spatial one-shots
                  removed: \(expired.count)
                  activeRemaining: \(activeSpatialOneShotsByID.count)
                """
            )
        }
    }

    private func pruneFinishedCharacterVocals() {
        let now = CACurrentMediaTime()
        let expiredSourceIDs = activeCharacterVocalBySourceID.compactMap { sourceID, vocal in
            vocal.expectedEndTime <= now ? sourceID : nil
        }

        for sourceID in expiredSourceIDs {
            activeCharacterVocalBySourceID.removeValue(
                forKey: sourceID
            )
        }

        if !expiredSourceIDs.isEmpty {
            print(
                """
                [CharacterAudio] pruned finished character vocals
                  channel: characterVocal
                  removed: \(expiredSourceIDs.count)
                  activeRemaining: \(activeCharacterVocalBySourceID.count)
                """
            )
        }
    }

    private func pruneOldestSpatialOneShot() {
        guard let oldest = activeSpatialOneShotsByID.values.min(
            by: { $0.startedAt < $1.startedAt }
        ) else {
            return
        }

        oldest.playbackController.stop()
        activeSpatialOneShotsByID.removeValue(
            forKey: oldest.id
        )
    }

    private func estimatedDurationSeconds(
        for file: BundleAudioFile,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard let url = bundleURL(for: file) else {
            return fallback
        }

        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)

        guard seconds.isFinite,
              seconds > 0 else {
            return fallback
        }

        return seconds
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
