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

    private var sceneRoot: Entity?
    private var deathHeadPose: PhaseOneSpawnPose?
    private var deathRunning = false
    private var deathPresentationRoot: Entity?
    private var deathRig: Entity?
    private var deathImageEntity: ModelEntity?
    private var deathBillboardOpacity: Float = 0.0

    private var jockRetargetController: JockRetargetTestController?
    private var hordeEnemyControllersByID: [UUID: JockRetargetTestController] = [:]
    private var activeHordeEnemyIDs = Set<UUID>()
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
    private let deathCardForwardMeters: Float = 1.25
    private let deathCardYDropMeters: Float = 0.10
    private let deathCardWidthMeters: Float = 0.85
    private let deathCardHeightMeters: Float = 0.42

    func makeSceneRoot() async -> Entity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = Entity()
        root.name = "GravitasPlague_PhaseOne_SceneRoot"

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
        _ = ensureDeathPresentationRoot(world: root)
        validateDeathPresentationAssets()

        drainPendingCommands()

        return root
    }

    private func wireJockCallbacks(
        _ jockController: JockRetargetTestController
    ) {
        jockController.onPunchHit = { [weak self] in
            Task { @MainActor in
                self?.audioController.playPunchHitAtHostHead()
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

        await spawnNextHordeWave()
    }

    private func stopHordeBenchmark() {
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil

        hordeBenchmarkRunning = false
        clearHordeEnemyControllers()
        activeHordeEnemyIDs.removeAll()
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

        hordeCurrentWave = nextWave
        hordePlayerHitsThisWave = 0
        hordeTotalSpawned += spawnCount

        var spawnedIDs: [UUID] = []

        for index in 0..<spawnCount {
            let id = UUID()
            let hitsToKill = Int.random(in: 3...5)
            let controller = JockRetargetTestController()

            wireJockCallbacks(controller)
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
                      position: \(positions[index])
                      entityName: \(controller.rootEntity.name)
                      entityObject: \(Unmanaged.passUnretained(controller.rootEntity).toOpaque())
                    """
                )
            } catch {
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
        for controller in hordeEnemyControllersByID.values {
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
        deathHeadPose = spatialProvider.currentPoseOrFallback()
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

            if let sceneRoot = self.sceneRoot,
               let deathHeadPose = self.deathHeadPose {
                self.playYouDiedRoomAnchored(
                    world: sceneRoot,
                    headPose: deathHeadPose
                )
            } else {
                print("[PlagueDeath] Cannot show you_died.png; missing world or head pose.")
            }

            self.clearHordeEnemiesAfterDeathBlackout()

            print("[PlagueDeath] final dark reached; horde cleared; you_died shown.")
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
            cleanupYouDiedBillboard()

            print("[PlagueDeath] lights coming back up.")
        }
    }

    private func resetHordeBenchmarkDeathPresentation() {
        pendingNextBenchmarkWaveTask?.cancel()
        pendingNextBenchmarkWaveTask = nil
        isPlayerDeathSequenceActive = false
        jockRetargetController?.setPlayerAttackEnabled(true)
        deathPresentationController?.reset()
        deathHeadPose = nil
        cleanupYouDiedBillboard()
    }

    private func clearHordeEnemiesAfterDeathBlackout() {
        for controller in hordeEnemyControllersByID.values {
            controller.stopForBenchmarkPlayerDeath()
            controller.rootEntity.removeFromParent()
        }

        hordeEnemyControllersByID.removeAll()
        activeHordeEnemyIDs.removeAll()
        hordeBenchmarkRunning = false
        audioController.stopDemoAudio()

        print("[PlagueDeath] horde enemies cleared after blackout; death billboard preserved.")
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

        if let controller = hordeEnemyControllersByID.removeValue(forKey: id) {
            controller.hide()
            controller.rootEntity.removeFromParent()
        }

        hordeTotalKilled += 1

        print(
            """
            [HordeBenchmark] enemy killed
              id: \(id)
              wave: \(wave)
              aliveRemaining: \(activeHordeEnemyIDs.count)
              activeEnemyIDs: \(activeHordeEnemyIDs.count)
              totalKilled: \(hordeTotalKilled)
            """
        )

        guard activeHordeEnemyIDs.isEmpty else { return }
        guard pendingNextBenchmarkWaveTask == nil else {
            print("[HordeBenchmark] wave clear ignored: next wave already pending")
            return
        }

        print(
            """
            [HordeBenchmark] wave cleared
              wave: \(wave)
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

            await spawnNextHordeWave()
        }
    }

    private func playYouDiedRoomAnchored(
        world: Entity,
        headPose: PhaseOneSpawnPose
    ) {
        guard !deathRunning else {
            print("[PlagueDeath] you_died already running.")
            return
        }

        let root = ensureDeathPresentationRoot(world: world)

        guard let texture = loadYouDiedTexture() else {
            return
        }

        cleanupYouDiedBillboard()
        deathRunning = true

        let headPosition = headPose.headPosition
        let forward = PhaseOneMath.normalizedOrFallback(
            headPose.headForward,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let targetPosition = headPosition +
            forward * deathCardForwardMeters -
            SIMD3<Float>(0, deathCardYDropMeters, 0)

        let rig = Entity()
        rig.name = "YouDiedRig"
        rig.position = targetPosition

        rig.look(
            at: headPosition,
            from: targetPosition,
            relativeTo: world
        )

        root.addChild(rig)

        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor.white.withAlphaComponent(0.0),
            texture: .init(texture)
        )
        material.blending = .transparent(opacity: 0.001)

        let imageEntity = ModelEntity(
            mesh: .generatePlane(
                width: deathCardWidthMeters,
                height: deathCardHeightMeters
            ),
            materials: [material]
        )

        imageEntity.name = "you_died.png"
        imageEntity.position = .zero

        rig.addChild(imageEntity)

        deathRig = rig
        deathImageEntity = imageEntity
        deathBillboardOpacity = 0.0

        print(
            """
            [PlagueDeath] you_died room anchored
              position: \(targetPosition)
              forward: \(forward)
              width: \(deathCardWidthMeters)
              height: \(deathCardHeightMeters)
              root: \(root.name)
              rigParent: \(rig.parent?.name ?? "nil")
            """
        )

        Task { @MainActor in
            await fadeYouDiedAlpha(
                to: 1.0,
                duration: 0.20
            )
        }
    }

    private func ensureDeathPresentationRoot(
        world: Entity
    ) -> Entity {
        if let deathPresentationRoot {
            return deathPresentationRoot
        }

        let root = Entity()
        root.name = "DeathPresentationRoot_DO_NOT_CLEAR_WITH_GAMEPLAY"
        world.addChild(root)

        deathPresentationRoot = root

        print("[PlagueDeath] death presentation root created")

        return root
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
        if let texture = try? TextureResource.load(named: "you_died") {
            print("[PlagueDeath] loaded texture named you_died")
            return texture
        }

        if let texture = try? TextureResource.load(named: "you_died.png") {
            print("[PlagueDeath] loaded texture named you_died.png")
            return texture
        }

        print("[PlagueDeath] ERROR: failed to load you_died.png")
        return nil
    }

    private func setYouDiedAlpha(
        _ alpha: Float
    ) {
        deathBillboardOpacity = max(0, min(1, alpha))

        guard let deathImageEntity,
              var material = deathImageEntity.model?.materials.first as? UnlitMaterial else {
            return
        }

        let texture = material.color.texture
        let clampedAlpha = max(0.001, deathBillboardOpacity)

        material.color = .init(
            tint: UIColor.white.withAlphaComponent(CGFloat(deathBillboardOpacity)),
            texture: texture
        )
        material.blending = .transparent(opacity: .init(floatLiteral: clampedAlpha))

        deathImageEntity.model?.materials = [material]
    }

    private func fadeYouDiedAlpha(
        to target: Float,
        duration: TimeInterval
    ) async {
        let start = deathBillboardOpacity
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

    private func cleanupYouDiedBillboard() {
        deathImageEntity?.removeFromParent()
        deathImageEntity = nil

        deathRig?.removeFromParent()
        deathRig = nil

        deathBillboardOpacity = 0.0
        deathRunning = false

        print("[PlagueDeath] you_died billboard cleaned up.")
    }
}
