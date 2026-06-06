import Foundation
import Combine
import QuartzCore
import RealityKit
import simd
import UIKit

@MainActor
final class PlagueImmersiveCoordinator: ObservableObject {
    private let spatialProvider = PhaseOneSpatialProvider()
    private let audioController = GravitasDemoAudioController()

    @Published private(set) var isPlayerDeathSequenceActive = false

    var onPlayerDamaged: ((Int) -> Void)?
    var onPlayerDeathStarted: (() -> Void)?
    weak var deathPresentationController: DeathPresentationController?

    private var sceneRoot: AnchorEntity?
    private var headAnchor: AnchorEntity?
    private var youDiedRunning = false
    private var youDiedRig: Entity?
    private var youDiedLogo: ModelEntity?
    private var youDiedAlpha: Float = 0.0

    private var jockRetargetController: JockRetargetTestController?
    private var hordeEnemyControllersByID: [UUID: JockRetargetTestController] = [:]
    private var activeHordeEnemyIDs = Set<UUID>()
    private var dyingHordeEnemyIDs = Set<UUID>()
    private var corpseHordeEnemyIDs = Set<UUID>()
    private var hordeBenchmarkRunning = false
    private var hordeCurrentWave = 0
    private var hordePlayerHitsThisWave = 0
    private var hordeTotalSpawned = 0
    private var hordeTotalKilled = 0

    private var lastTickDate: Date?
    private var handledCommandIDs = Set<UUID>()
    private var pendingCommands: [PlagueDemoSession.CommandEnvelope] = []
    private var pendingNextBenchmarkWaveTask: Task<Void, Never>?

    private let benchmarkNextWaveDelaySeconds: TimeInterval = 1.20
    private let hordePlayerHitLimitPerWave = 3
    private let hordeSpawnRadiusMeters: Float = 2.45
    private let YOU_DIED_FORWARD_M: Float = 1.25
    private let YOU_DIED_Y_OFFSET_M: Float = 7.0 * 0.3048
    private let YOU_DIED_WIDTH_M: Float = 1.70
    private let YOU_DIED_HEIGHT_M: Float = 0.84

    func makeSceneRoot() async -> AnchorEntity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        root.name = "GravitasPlague_PhaseOne_SceneRoot"

        _ = makeHeadAnchor()

        audioController.startImmersiveAudio()

        await spatialProvider.start()

        let jockController = JockRetargetTestController()
        wireJockCallbacks(jockController)
        root.addChild(jockController.rootEntity)

        audioController.attachToSceneIfNeeded(
            sceneRoot: root,
            hostRootEntity: jockController.rootEntity
        )

        self.sceneRoot = root
        self.jockRetargetController = jockController
        validateDeathPresentationAssets()

        drainPendingCommands()

        return root
    }

    func makeHeadAnchor() -> AnchorEntity {
        if let headAnchor {
            return headAnchor
        }

        let head = AnchorEntity(.head)
        head.name = "GravitasPlague_HeadAnchor"
        headAnchor = head

        return head
    }

    private func wireJockCallbacks(
        _ jockController: JockRetargetTestController,
        hostAudioSourceID: UUID? = nil
    ) {
        jockController.onPunchHit = { [weak self] in
            Task { @MainActor in
                self?.audioController.playPunchHitAtHostHead(
                    sourceID: hostAudioSourceID
                )
            }
        }

        jockController.onPlayerDamaged = { [weak self] amount in
            Task { @MainActor in
                self?.audioController.playRandomPlayerDamageHit()
                self?.onPlayerDamaged?(amount)
            }
        }

        jockController.onBenchmarkPlayerHit = { [weak self] amount, attackerID in
            guard let self else { return false }

            return self.registerConfirmedHordePlayerHit(
                amount: amount,
                attackerID: attackerID
            )
        }

        jockController.onBenchmarkPlayerDeath = { [weak self] wave, hitsThisWave in
            Task { @MainActor in
                self?.handleHordeBenchmarkPlayerDeath(
                    wave: wave,
                    hitsThisWave: hitsThisWave
                )
            }
        }

        jockController.onBenchmarkEnemyKilled = { [weak self] id, wave in
            Task { @MainActor in
                self?.handleBenchmarkEnemyKilled(
                    id: id,
                    wave: wave
                )
            }
        }

        jockController.onBenchmarkEnemyDeathAnimationFinished = { [weak self] id, wave in
            Task { @MainActor in
                self?.handleBenchmarkEnemyDeathAnimationFinished(
                    id: id,
                    wave: wave
                )
            }
        }

        jockController.onAttackStarted = {
            print("[Gravitas Attack] Attack animation started.")
        }
    }

    func handle(_ envelope: PlagueDemoSession.CommandEnvelope) {
        guard !handledCommandIDs.contains(envelope.id) else { return }

        guard sceneRoot != nil else {
            pendingCommands.append(envelope)
            return
        }

        handledCommandIDs.insert(envelope.id)
        perform(envelope.command)
    }

    private func perform(_ command: PlagueDemoSession.Command) {
        switch command {
        case .startJockRetargetTest:
            Task {
                await startJockRetargetTest(autoPlayLoop: false)
            }

        case .playJockPacingLoop:
            Task {
                await startJockRetargetTest(autoPlayLoop: true)
            }

        case .playJockFollowDemo:
            Task {
                await startJockRetargetTest(autoPlayLoop: false)
                await startHordeBenchmark()
            }

        case .stopJockFollowDemo:
            stopHordeBenchmark()
            jockRetargetController?.stopFollowDemo()

        case .playJockClip(let clipID, let loop):
            do {
                try jockRetargetController?.playClip(
                    id: clipID,
                    loop: loop
                )
            } catch {
                assertionFailure("Failed to play JockAsset clip \(clipID): \(error)")
            }

        case .stopJockClip:
            jockRetargetController?.stopFollowDemo()
            jockRetargetController?.stopClip()

        case .resetJockPose:
            jockRetargetController?.resetPose()

        case .closeDemo:
            stopHordeBenchmark()
            jockRetargetController?.hide()
            spatialProvider.stop()
            audioController.stopAllAudio()
            resetHordeBenchmarkDeathPresentation()
        }
    }

    func tick(at date: Date) {
        let deltaTime: Float

        if let lastTickDate {
            deltaTime = min(Float(date.timeIntervalSince(lastTickDate)), 0.1)
        } else {
            deltaTime = 1.0 / 60.0
        }

        lastTickDate = date

        let currentHeadPosition = spatialProvider.currentPose()?.headPosition

        if hordeBenchmarkRunning {
            for controller in hordeEnemyControllersByID.values {
                controller.update(
                    deltaTime: deltaTime,
                    currentHeadPosition: currentHeadPosition
                )
            }
        } else {
            jockRetargetController?.update(
                deltaTime: deltaTime,
                currentHeadPosition: currentHeadPosition
            )
        }
    }

    func shutdown() {
        stopHordeBenchmark()
        jockRetargetController?.hide()
        spatialProvider.stop()
        audioController.stopAllAudio()
        resetHordeBenchmarkDeathPresentation()

        sceneRoot = nil
        headAnchor = nil
        jockRetargetController = nil
        lastTickDate = nil
        handledCommandIDs.removeAll()
        pendingCommands.removeAll()
    }

    private func drainPendingCommands() {
        let commandsToDrain = pendingCommands
        pendingCommands.removeAll()

        for command in commandsToDrain {
            handle(command)
        }
    }

    private func startJockRetargetTest(autoPlayLoop: Bool) async {
        guard let jockRetargetController else { return }

        do {
            stopHordeBenchmark()
            resetHordeBenchmarkDeathPresentation()

            try await jockRetargetController.loadIfNeeded()

            let spawnPose = spatialProvider.currentPoseOrFallback()
            let config = PhaseOneConfiguration.phaseOneDefault

            let floorY = await spatialProvider.resolvedFloorY(
                for: spawnPose,
                fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
                timeoutSeconds: config.floorDetectionTimeoutSeconds
            )

            audioController.startDemoAudio(
                spawnPose: spawnPose,
                floorY: floorY
            )
            audioController.startPrimaryHostDadBreathing()

            jockRetargetController.configureSpawn(
                using: spawnPose,
                floorY: floorY
            )

            jockRetargetController.show()

            if autoPlayLoop {
                try jockRetargetController.playPacingLoopFromStart()
            }
        } catch {
            assertionFailure("Failed to start JockAsset Retarget Test: \(error)")
        }
    }

    private func startHordeBenchmark() async {
        guard sceneRoot != nil else { return }

        stopHordeBenchmark()
        resetHordeBenchmarkDeathPresentation()

        hordeBenchmarkRunning = true
        hordeCurrentWave = 0
        hordePlayerHitsThisWave = 0
        hordeTotalSpawned = 0
        hordeTotalKilled = 0

        jockRetargetController?.hide()
        audioController.stopPrimaryHostDadBreathing()

        await spawnNextHordeWave()
    }

    private func stopHordeBenchmark() {
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil

        hordeBenchmarkRunning = false
        clearHordeEnemyControllers()
        activeHordeEnemyIDs.removeAll()
        dyingHordeEnemyIDs.removeAll()
        corpseHordeEnemyIDs.removeAll()
        hordePlayerHitsThisWave = 0
    }

    private func spawnNextHordeWave() async {
        guard hordeBenchmarkRunning else {
            print("[HordeBenchmark] spawnNextWave ignored: benchmark not running")
            return
        }

        guard !isPlayerDeathSequenceActive else {
            print("[HordeBenchmark] spawnNextWave ignored: player dead")
            return
        }

        guard let sceneRoot else { return }

        let spawnPose = spatialProvider.currentPoseOrFallback()
        let config = PhaseOneConfiguration.phaseOneDefault

        let floorY = await spatialProvider.resolvedFloorY(
            for: spawnPose,
            fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
            timeoutSeconds: config.floorDetectionTimeoutSeconds
        )

        let nextWave = hordeCurrentWave + 1
        let spawnCount = nextWave
        let positions = hordeSpawnPositions(
            count: spawnCount,
            spawnPose: spawnPose,
            floorY: floorY
        )

        guard positions.count == spawnCount else {
            print(
                """
                [HordeBenchmark] ERROR spawn position count mismatch
                  wave: \(nextWave)
                  spawnCount: \(spawnCount)
                  positions: \(positions.count)
                """
            )
            return
        }

        clearHordeEnemyControllers()
        activeHordeEnemyIDs.removeAll()
        dyingHordeEnemyIDs.removeAll()
        corpseHordeEnemyIDs.removeAll()

        hordeCurrentWave = nextWave
        hordePlayerHitsThisWave = 0
        hordeTotalSpawned += spawnCount

        var spawnedIDs: [UUID] = []

        for index in 0..<spawnCount {
            let id = UUID()
            let hitsToKill = Int.random(in: 3...5)
            let controller = JockRetargetTestController()

            wireJockCallbacks(
                controller,
                hostAudioSourceID: id
            )
            sceneRoot.addChild(controller.rootEntity)

            do {
                try await controller.loadIfNeeded()

                controller.configureHordeIdentity(
                    id: id,
                    wave: nextWave,
                    spawnIndex: index,
                    hitsToKill: hitsToKill
                )

                controller.configureHordeSpawn(
                    position: positions[index],
                    playerHeadPosition: spawnPose.headPosition
                )

                let audioStartDelay = TimeInterval.random(in: 0...1)
                audioController.attachHostAudioSource(
                    id: id,
                    hostRootEntity: controller.rootEntity,
                    breathingStartDelay: audioStartDelay
                )

                try controller.playFollowDemo(
                    resetBenchmarkState: false
                )

                hordeEnemyControllersByID[id] = controller
                activeHordeEnemyIDs.insert(id)
                spawnedIDs.append(id)

                print(
                    """
                    [HordeBenchmark] spawned infected
                      wave: \(nextWave)
                      index: \(index)
                      id: \(id)
                      hitsToKill: \(hitsToKill)
                      audioStartDelay: \(String(format: "%.3f", audioStartDelay))
                      position: \(positions[index])
                      entityName: \(controller.rootEntity.name)
                      entityObject: \(Unmanaged.passUnretained(controller.rootEntity).toOpaque())
                    """
                )
            } catch {
                audioController.stopHostAudioSource(id: id)
                controller.rootEntity.removeFromParent()

                print(
                    """
                    [HordeBenchmark] ERROR failed to spawn infected
                      wave: \(nextWave)
                      index: \(index)
                      id: \(id)
                      error: \(error)
                    """
                )
            }
        }

        let aliveEnemies = activeHordeEnemyIDs.count

        print(
            """
            [HordeBenchmark] wave spawned
              wave: \(nextWave)
              requestedCount: \(spawnCount)
              positionsCount: \(positions.count)
              spawnedIDs: \(spawnedIDs.count)
              activeEnemyIDs: \(activeHordeEnemyIDs.count)
              aliveEnemies: \(aliveEnemies)
              totalSpawned: \(hordeTotalSpawned)
            """
        )

        validateWaveSpawnCount(
            expected: spawnCount
        )
    }

    private func hordeSpawnPositions(
        count: Int,
        spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) -> [SIMD3<Float>] {
        guard count > 0 else { return [] }

        let front = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(
                spawnPose.headForward.x,
                0,
                spawnPose.headForward.z
            ),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let right = PhaseOneMath.normalizedOrFallback(
            simd_cross(front, SIMD3<Float>(0, 1, 0)),
            fallback: SIMD3<Float>(1, 0, 0)
        )

        let angles: [Float]

        if count == 1 {
            angles = [0]
        } else if count == 2 {
            angles = [0, .pi]
        } else {
            angles = (0..<count).map { index in
                Float(index) * 2.0 * .pi / Float(count)
            }
        }

        return angles.map { angle in
            let direction = PhaseOneMath.normalizedOrFallback(
                front * cos(angle) + right * sin(angle),
                fallback: front
            )

            return SIMD3<Float>(
                spawnPose.headPosition.x + direction.x * hordeSpawnRadiusMeters,
                floorY,
                spawnPose.headPosition.z + direction.z * hordeSpawnRadiusMeters
            )
        }
    }

    private func validateWaveSpawnCount(
        expected: Int
    ) {
        let activeIDCount = activeHordeEnemyIDs.count
        let activeControllerCount = hordeEnemyControllersByID.count

        print(
            """
            [HordeBenchmark] wave spawn validation
              wave: \(hordeCurrentWave)
              expected: \(expected)
              activeEnemyIDs: \(activeIDCount)
              activeControllers: \(activeControllerCount)
              aliveEnemies: \(activeIDCount)
            """
        )

        if activeIDCount != expected ||
            activeControllerCount != expected {
            print(
                """
                [HordeBenchmark] ERROR wave spawned wrong count
                  expected: \(expected)
                  activeEnemyIDs: \(activeIDCount)
                  activeControllers: \(activeControllerCount)
                """
            )
        }
    }

    private func clearHordeEnemyControllers() {
        for (id, controller) in hordeEnemyControllersByID {
            audioController.stopHostAudioSource(id: id)
            controller.hide()
            controller.rootEntity.removeFromParent()
        }

        hordeEnemyControllersByID.removeAll()
    }

    @discardableResult
    private func registerConfirmedHordePlayerHit(
        amount: Int,
        attackerID: UUID?
    ) -> Bool {
        guard hordeBenchmarkRunning else { return false }
        guard !isPlayerDeathSequenceActive else { return true }

        hordePlayerHitsThisWave += 1

        print(
            """
            [HordeBenchmark] confirmed player hit
              wave: \(hordeCurrentWave)
              hitsThisWave: \(hordePlayerHitsThisWave)
              limit: \(hordePlayerHitLimitPerWave)
              amount: \(amount)
              attackerID: \(attackerID?.uuidString ?? "nil")
            """
        )

        guard hordePlayerHitsThisWave >= hordePlayerHitLimitPerWave else {
            return false
        }

        handleHordeBenchmarkPlayerDeath(
            wave: hordeCurrentWave,
            hitsThisWave: hordePlayerHitsThisWave
        )

        return true
    }

    private func handleHordeBenchmarkPlayerDeath(
        wave: Int,
        hitsThisWave: Int
    ) {
        guard !isPlayerDeathSequenceActive else { return }

        isPlayerDeathSequenceActive = true
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        jockRetargetController?.setPlayerAttackEnabled(false)

        for controller in hordeEnemyControllersByID.values {
            controller.setBenchmarkPlayerDead(true)
            controller.setPlayerAttackEnabled(false)
        }

        print(
            """
            [HordeBenchmark] Handling player death
              wave: \(wave)
              hitsThisWave: \(hitsThisWave)
            """
        )

        let deathAudioDuration = audioController.playRandomPlayerDeathAndReturnDuration()
        onPlayerDeathStarted?()

        deathPresentationController?.playDeathBlackoutSequence { [weak self] in
            guard let self else { return }

            self.clearHordeEnemiesAfterDeathBlackout()

            if let sceneRoot = self.sceneRoot,
               let headAnchor = self.headAnchor {
                self.playYouDiedRoomAnchored(
                    world: sceneRoot,
                    head: headAnchor
                )
            } else {
                print("[PlagueDeath] Cannot show you_died.png; missing world or head anchor.")
            }

            print("[PlagueDeath] final dark reached; horde cleared; you_died shown after cleanup.")
        }

        Task { @MainActor in
            let delay = deathAudioDuration + 3.0

            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )

            guard isPlayerDeathSequenceActive else { return }

            deathPresentationController?.fadeBackUp(duration: 1.25)
            await fadeYouDiedAlpha(
                to: 0.0,
                duration: 0.30
            )
            cleanupYouDied()

            print("[PlagueDeath] lights coming back up.")
        }
    }

    private func resetHordeBenchmarkDeathPresentation() {
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        isPlayerDeathSequenceActive = false
        jockRetargetController?.setPlayerAttackEnabled(true)
        deathPresentationController?.reset()
        cleanupYouDied()
    }

    private func clearHordeEnemiesAfterDeathBlackout() {
        for (id, controller) in hordeEnemyControllersByID {
            audioController.stopHostAudioSource(id: id)
            controller.stopForBenchmarkPlayerDeath()
            controller.rootEntity.removeFromParent()
        }

        hordeEnemyControllersByID.removeAll()
        activeHordeEnemyIDs.removeAll()
        dyingHordeEnemyIDs.removeAll()
        corpseHordeEnemyIDs.removeAll()
        hordeBenchmarkRunning = false
        audioController.stopDemoAudio()

        print("[PlagueDeath] active enemies and corpses cleared after final dark; death billboard preserved.")
    }

    private func handleBenchmarkEnemyKilled(
        id: UUID,
        wave: Int
    ) {
        guard !isPlayerDeathSequenceActive else {
            print("[HordeBenchmark] enemyKilled ignored: player death active")
            return
        }

        guard activeHordeEnemyIDs.contains(id) else {
            print(
                """
                [HordeBenchmark] WARNING enemyKilled id not active
                  id: \(id)
                  activeIDsCount: \(activeHordeEnemyIDs.count)
                  activeIDs: \(activeHordeEnemyIDs.map { $0.uuidString }.joined(separator: ", "))
                """
            )
            return
        }

        activeHordeEnemyIDs.remove(id)
        dyingHordeEnemyIDs.insert(id)
        audioController.stopHostDadBreathing(id: id)

        hordeTotalKilled += 1

        print(
            """
            [HordeBenchmark] kill shot confirmed
              id: \(id)
              wave: \(wave)
              aliveRemaining: \(activeHordeEnemyIDs.count)
              active: \(activeHordeEnemyIDs.count)
              dying: \(dyingHordeEnemyIDs.count)
              corpses: \(corpseHordeEnemyIDs.count)
              totalKilled: \(hordeTotalKilled)
            """
        )

        checkWaveCanEnd(
            wave: wave
        )
    }

    private func handleBenchmarkEnemyDeathAnimationFinished(
        id: UUID,
        wave: Int
    ) {
        if dyingHordeEnemyIDs.contains(id) {
            dyingHordeEnemyIDs.remove(id)
            corpseHordeEnemyIDs.insert(id)
        } else if !corpseHordeEnemyIDs.contains(id) {
            print(
                """
                [HordeBenchmark] WARNING death animation finished for unknown id
                  id: \(id)
                  active: \(activeHordeEnemyIDs.count)
                  dying: \(dyingHordeEnemyIDs.count)
                  corpses: \(corpseHordeEnemyIDs.count)
                """
            )
            corpseHordeEnemyIDs.insert(id)
        }

        print(
            """
            [HordeBenchmark] corpse registered
              id: \(id)
              wave: \(wave)
              active: \(activeHordeEnemyIDs.count)
              dying: \(dyingHordeEnemyIDs.count)
              corpses: \(corpseHordeEnemyIDs.count)
            """
        )

        checkWaveCanEnd(
            wave: wave
        )
    }

    private func checkWaveCanEnd(
        wave: Int
    ) {
        guard hordeBenchmarkRunning else { return }
        guard !isPlayerDeathSequenceActive else { return }
        guard pendingNextBenchmarkWaveTask == nil else {
            print("[HordeBenchmark] wave clear ignored: next wave already pending")
            return
        }

        guard activeHordeEnemyIDs.isEmpty,
              dyingHordeEnemyIDs.isEmpty else {
            print(
                """
                [HordeBenchmark] wave not clear yet
                  wave: \(wave)
                  active: \(activeHordeEnemyIDs.count)
                  dying: \(dyingHordeEnemyIDs.count)
                  corpses: \(corpseHordeEnemyIDs.count)
                """
            )
            return
        }

        print(
            """
            [HordeBenchmark] wave cleared
              wave: \(wave)
              corpsesToClear: \(corpseHordeEnemyIDs.count)
              nextWave: \(wave + 1)
            """
        )

        pendingNextBenchmarkWaveTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(benchmarkNextWaveDelaySeconds * 1_000_000_000)
            )

            pendingNextBenchmarkWaveTask = nil

            guard hordeBenchmarkRunning,
                  !isPlayerDeathSequenceActive else { return }

            clearWaveCorpses()

            await spawnNextHordeWave()
        }
    }

    private func clearWaveCorpses() {
        let ids = corpseHordeEnemyIDs

        print(
            """
            [HordeBenchmark] clearing wave corpses
              count: \(ids.count)
              ids: \(ids.map { $0.uuidString }.joined(separator: ", "))
            """
        )

        for id in ids {
            audioController.stopHostAudioSource(id: id)

            if let controller = hordeEnemyControllersByID.removeValue(forKey: id) {
                controller.hide()
                controller.rootEntity.removeFromParent()
            }
        }

        corpseHordeEnemyIDs.removeAll()
    }

    private func playYouDiedRoomAnchored(
        world: AnchorEntity,
        head: AnchorEntity
    ) {
        guard !youDiedRunning else {
            print("[PlagueDeath] you_died already running.")
            return
        }

        cleanupYouDied()
        youDiedRunning = true

        let headMatrix = head.transformMatrix(relativeTo: world)
        let headPosition = head.position(relativeTo: world)

        var forward = -SIMD3<Float>(
            headMatrix.columns.2.x,
            headMatrix.columns.2.y,
            headMatrix.columns.2.z
        )

        if simd_length(forward) < 0.0001 {
            forward = SIMD3<Float>(0, 0, -1)
        } else {
            forward = simd_normalize(forward)
        }

        let targetPosition = headPosition +
            forward * YOU_DIED_FORWARD_M +
            SIMD3<Float>(0, YOU_DIED_Y_OFFSET_M, 0)

        let rig = Entity()
        rig.name = "YouDiedRig"
        rig.position = targetPosition

        let directionToHead = PhaseOneMath.normalizedOrFallback(
            headPosition - targetPosition,
            fallback: SIMD3<Float>(0, 0, 1)
        )
        let upWorld = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(upWorld, directionToHead)
        if simd_length_squared(right) < 1e-6 {
            right = SIMD3<Float>(1, 0, 0)
        }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(directionToHead, right))
        let rotation = simd_float3x3(
            columns: (
                right,
                up,
                directionToHead
            )
        )
        rig.orientation = simd_quatf(rotation)

        guard let texture = loadYouDiedTexture() else {
            print("[PlagueDeath] ERROR: could not load you_died.png")
            youDiedRunning = false
            return
        }

        let material = makeYouDiedMaterialFromDarkMatterPattern(
            texture: texture,
            alpha: 0.0
        )

        let imageSize = loadYouDiedImageSize()
        let aspect = max(
            0.01,
            (imageSize?.width ?? 1672) / max(1, imageSize?.height ?? 941)
        )
        let heightMeters = YOU_DIED_HEIGHT_M
        let widthMeters = min(
            YOU_DIED_WIDTH_M,
            heightMeters * Float(aspect)
        )

        let imageEntity = ModelEntity(
            mesh: .generatePlane(
                width: widthMeters,
                height: heightMeters
            ),
            materials: [material]
        )

        imageEntity.name = "you_died.png"
        imageEntity.position = .zero

        rig.addChild(imageEntity)
        world.addChild(rig)

        youDiedRig = rig
        youDiedLogo = imageEntity
        youDiedAlpha = 0.0

        print(
            """
            [PlagueDeath] you_died room anchored
              world: \(world.name)
              head: \(head.name)
              rigParent: \(rig.parent?.name ?? "nil")
              logoParent: \(imageEntity.parent?.name ?? "nil")
              headPosition: \(headPosition)
              rigPosition: \(targetPosition)
              forward: \(forward)
              distanceFromHead: \(simd_length(targetPosition - headPosition))
              width: \(widthMeters)
              height: \(heightMeters)
            """
        )

        dumpYouDiedDiagnostic()

        Task { @MainActor in
            await fadeYouDiedAlpha(
                to: 1.0,
                duration: 0.20
            )
        }
    }

    private func validateDeathPresentationAssets() {
        if Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ) == nil {
            print("[PlagueDeath] WARNING you_died.png not found in main bundle")
        }
    }

    private func loadYouDiedTexture() -> TextureResource? {
        if let url = Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ) {
            print("[PlagueDeath] found you_died.png in bundle: \(url.path)")
        } else {
            print("[PlagueDeath] WARNING: Bundle.main cannot find you_died.png")
        }

        if let texture = try? TextureResource.load(named: "you_died") {
            print("[PlagueDeath] loaded TextureResource named you_died")
            return texture
        }

        if let texture = try? TextureResource.load(named: "you_died.png") {
            print("[PlagueDeath] loaded TextureResource named you_died.png")
            return texture
        }

        print("[PlagueDeath] ERROR: TextureResource.load failed for you_died and you_died.png")
        return nil
    }

    private func loadYouDiedImageSize() -> CGSize? {
        if let image = UIImage(named: "you_died") {
            return image.size
        }

        guard let url = Bundle.main.url(
            forResource: "you_died",
            withExtension: "png"
        ),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }

        return image.size
    }

    private func makeYouDiedMaterialFromDarkMatterPattern(
        texture: TextureResource,
        alpha: Float
    ) -> UnlitMaterial {
        let alpha = max(0, min(1, alpha))

        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor.white.withAlphaComponent(CGFloat(alpha)),
            texture: .init(texture)
        )
        material.blending = .transparent(opacity: .init(floatLiteral: max(0.001, alpha)))

        return material
    }

    private func setYouDiedAlpha(
        _ alpha: Float
    ) {
        youDiedAlpha = max(0, min(1, alpha))

        guard let logo = youDiedLogo,
              var material = logo.model?.materials.first as? UnlitMaterial else {
            print("[PlagueDeath] setYouDiedAlpha ignored: no logo material")
            return
        }

        let texture = material.color.texture

        material.color = .init(
            tint: UIColor.white.withAlphaComponent(CGFloat(youDiedAlpha)),
            texture: texture
        )
        material.blending = .transparent(opacity: .init(floatLiteral: max(0.001, youDiedAlpha)))

        logo.model?.materials = [material]

        print("[PlagueDeath] you_died alpha set: \(youDiedAlpha)")
    }

    private func fadeYouDiedAlpha(
        to target: Float,
        duration: TimeInterval
    ) async {
        let start = youDiedAlpha
        let startTime = CACurrentMediaTime()

        while !Task.isCancelled {
            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(1.0, elapsed / max(duration, 0.001))
            let eased = Float(progress * progress * (3.0 - 2.0 * progress))
            let value = start + (target - start) * eased

            setYouDiedAlpha(value)

            if progress >= 1.0 {
                break
            }

            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func cleanupYouDied() {
        youDiedLogo?.removeFromParent()
        youDiedLogo = nil

        youDiedRig?.removeFromParent()
        youDiedRig = nil

        youDiedAlpha = 0.0
        youDiedRunning = false

        print("[PlagueDeath] you_died cleaned up")
    }

    private func dumpYouDiedDiagnostic() {
        print(
            """
            [PlagueDeath] you_died diagnostic
              youDiedRunning: \(youDiedRunning)
              hasRig: \(youDiedRig != nil)
              hasLogo: \(youDiedLogo != nil)
              rigParent: \(youDiedRig?.parent?.name ?? "nil")
              logoParent: \(youDiedLogo?.parent?.name ?? "nil")
              logoIsEnabled: \(youDiedLogo?.isEnabled ?? false)
              logoPosition: \(youDiedLogo?.position ?? .zero)
              rigPosition: \(youDiedRig?.position ?? .zero)
              alpha: \(youDiedAlpha)
              materialCount: \(youDiedLogo?.model?.materials.count ?? 0)
            """
        )
    }
}
