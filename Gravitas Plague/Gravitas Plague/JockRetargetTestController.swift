import Foundation
import RealityKit
import simd

@MainActor
final class JockRetargetTestController {
    private enum FollowDemoState: Equatable {
        case inactive
        case idleStopped
        case waitingToFollow
        case following
    }

    enum InfectedLifecycleState: String {
        case alive
        case dying
        case corpse
        case despawned
    }

    enum RetargetError: LocalizedError {
        case missingCharacterAsset(PlagueCharacterArchetype)
        case noSkinnedModelEntity(PlagueCharacterArchetype)
        case rigValidationFailed([String])
        case clipNotFound(String)
        case pacingLoopMissingClips([String])

        var errorDescription: String? {
            switch self {
            case .missingCharacterAsset(let archetype):
                return "Missing \(archetype.usdzFileName)."
            case .noSkinnedModelEntity(let archetype):
                return "\(archetype.usdzFileName) loaded, but no ModelEntity with jointNames was found."
            case .rigValidationFailed(let missing):
                return "Rig validation failed. Missing joints: \(missing.joined(separator: ", "))"
            case .clipNotFound(let id):
                return "JockAsset clip not found: \(id)"
            case .pacingLoopMissingClips(let ids):
                return "Pacing loop is missing clips: \(ids.joined(separator: ", "))"
            }
        }
    }

    private struct InfectedHeadHitZone {
        let centerWorld: SIMD3<Float>
        let radiusMeters: Float
        let jointDescription: String
        let headWorld: SIMD3<Float>?
        let headEndWorld: SIMD3<Float>?
        let headFrontWorld: SIMD3<Float>?
    }

    let rootEntity = Entity()

    var onPunchHit: (() -> Void)?
    var onPlayerDamaged: ((Int) -> Void)?
    var onBenchmarkPlayerHit: ((Int, UUID?) -> Bool)?
    var onBenchmarkPlayerDeath: ((Int, Int) -> Void)?
    var onBenchmarkEnemyKilled: ((UUID, Int) -> Void)?
    var onBenchmarkEnemyDeathAnimationFinished: ((UUID, Int) -> Void)?
    var onAttackStarted: (() -> Void)?

    private let visualOffsetEntity = Entity()

    private var characterEntity: Entity?
    private var modelEntity: ModelEntity?

    private var rigDefinition: JockRigDefinition?
    private var skeletonMap: JockSkeletonMap?
    private var manifest: JockAnimationManifest?
    private var adapter: JockSkeletonAdapter?
    private var driver: JockRuntimeDriver?
    private var skeletonWorldPoseResolver: JockSkeletonWorldPoseResolver?

    private var clipsByID: [String: JockAnimClip] = [:]
    private var runtimeOverrides = JockRuntimeClipOverrides(
        schema: "com.gravitas.jock_runtime_clip_overrides.v0",
        clips: [:]
    )

    private var hasLoaded = false
    private var isVisible = false
    private var rootYawRadians: Float = 0

    private var isPlayingPacingLoop = false
    private var pacingLoopSteps: [JockPacingLoopStep] = JockPacingLoopStep.gravitasPresenceLoop
    private var pacingLoopIndex = 0

    private var followDemoState: FollowDemoState = .inactive
    private var followConfiguration = JockFollowDemoConfiguration.defaultDemo
    private var latestHeadPosition: SIMD3<Float>?
    private var followDelayElapsed: TimeInterval = 0

    private let hitConfiguration = JockHitReactionConfiguration.phaseOne
    private lazy var hitDetector = JockHandHitDetector(
        configuration: hitConfiguration
    )

    private enum FollowCombatState: Equatable {
        case normal
        case closeRangeReady(delayRemaining: TimeInterval)
        case attacking
        case hitReaction(clipID: String, damage: JockHitDamageLevel)
        case dead
    }

    private var combatState: FollowCombatState = .normal
    private var activeAttack: JockActiveAttackState?
    private let attackConfiguration = JockAttackConfiguration.phaseOne
    private var playerExposure: Int = 0
    private var escalateAfterHitReact = false
    private let benchmarkPlayerHitLimitPerWave = 3
    private var benchmarkCurrentWave = 0
    private var benchmarkPlayerHitsThisWave = 0
    private var isBenchmarkPlayerDead = false
    private var playerAttackEnabled = true
    private var characterArchetype: PlagueCharacterArchetype = .dad
    private var hordeID = UUID()
    private var hordeWave = 1
    private var hordeSpawnIndex = 0
    private var hitsToKill = Int.random(in: 3...5)
    private var lifecycleState: InfectedLifecycleState = .alive
    private var activeDeathClipID: String?
    private var acceptedHitCount: Int = 0
    private var lastHitClipIDBySide: [JockHitSide: String] = [:]
    private var lastHitClipIDByBucket: [String: String] = [:]
    private var hasLoggedHeadHitZoneBuild = false
    private var hasLoggedMissingHeadHitZone = false

    private var spawnPosition = SIMD3<Float>(0, 0, -3.05)
    private var spawnOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var cameraFacingVisualOffset = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )
    private var loopStartVisualOffset = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )

    private(set) var debugStatus: String = "Retarget test not loaded."

    var debugHitStatus: String {
        switch combatState {
        case .normal:
            return "Hits: \(acceptedHitCount)/\(hitsToKill)"

        case .closeRangeReady(let delayRemaining):
            return "Close range: \(String(format: "%.2f", delayRemaining))s | Hits: \(acceptedHitCount)/\(hitsToKill) | Exposure: \(playerExposure)/\(attackConfiguration.exposureMax)"

        case .attacking:
            return "Attacking: \(activeAttack?.clipID ?? "none") | Hits: \(acceptedHitCount)/\(hitsToKill) | Exposure: \(playerExposure)/\(attackConfiguration.exposureMax)"

        case .hitReaction(let clipID, let damage):
            return "Hit reaction: \(clipID) \(damage.rawValue) | Hits: \(acceptedHitCount)/\(hitsToKill)"

        case .dead:
            return "Dead | Hits: \(acceptedHitCount)/\(hitsToKill)"
        }
    }

    private var isActionLocked: Bool {
        switch combatState {
        case .normal:
            return false
        case .closeRangeReady, .attacking, .hitReaction, .dead:
            return true
        }
    }

    private var isInNonInterruptibleCombatState: Bool {
        switch combatState {
        case .hitReaction, .dead:
            return true
        case .normal, .closeRangeReady, .attacking:
            return false
        }
    }

    private var canUpdateFollowMovement: Bool {
        switch combatState {
        case .normal:
            return true
        case .closeRangeReady, .attacking, .hitReaction, .dead:
            return false
        }
    }

    private func resetHitSelectionMemory() {
        lastHitClipIDBySide.removeAll()
        lastHitClipIDByBucket.removeAll()
    }

    private func resetCombatRuntime(resetHitCount: Bool = true) {
        combatState = .normal
        activeAttack = nil
        escalateAfterHitReact = false
        playerExposure = 0

        if resetHitCount {
            acceptedHitCount = 0
        }
    }

    init() {
        rootEntity.name = "Gravitas_JockRetargetTestRoot"
        rootEntity.isEnabled = false

        visualOffsetEntity.name = "Gravitas_JockVisualOffsetEntity"
        rootEntity.addChild(visualOffsetEntity)
    }

    var availableClipSummaries: [JockAnimationManifest.ClipSummary] {
        manifest?.clips.filter { $0.approvedForRuntime } ?? []
    }

    func loadIfNeeded() async throws {
        guard !hasLoaded else { return }

        guard let url = CharacterAssetRegistry.url(
            for: characterArchetype
        ) else {
            print(
                """
                [CharacterAssetRegistry] ERROR missing required character asset at load
                  archetype: \(characterArchetype.rawValue)
                  file: \(characterArchetype.usdzFileName)
                """
            )
            throw RetargetError.missingCharacterAsset(characterArchetype)
        }

        print(
            """
            [CharacterAssetRegistry] loading character asset
              archetype: \(characterArchetype.rawValue)
              file: \(characterArchetype.usdzFileName)
              url: \(url.path)
            """
        )

        let loadedEntity: Entity

        do {
            loadedEntity = try await Entity(contentsOf: url)
        } catch {
            print(
                """
                [CharacterAssetRegistry] ERROR RealityKit failed to load character asset
                  archetype: \(characterArchetype.rawValue)
                  file: \(characterArchetype.usdzFileName)
                  url: \(url.path)
                  error: \(error)
                """
            )

            throw error
        }

        loadedEntity.name = "\(characterArchetype.usdzResourceName)_loaded_character"

        CharacterRigValidator.validate(
            archetype: characterArchetype,
            root: loadedEntity
        )

        guard let skinnedModel = firstSkinnedModelEntity(in: loadedEntity) else {
            print(
                """
                [CharacterAssetRegistry] ERROR character asset has no skinned ModelEntity joints
                  archetype: \(characterArchetype.rawValue)
                  file: \(characterArchetype.usdzFileName)
                  url: \(url.path)
                  reason: Runtime requires a skinned ModelEntity with non-empty jointNames. Check the USDZ for a valid UsdSkel Skeleton under a SkelRoot.
                  entityTreeSample:
                \(loadedEntity.debugTreeSummary(limit: 48))
                """
            )

            throw RetargetError.noSkinnedModelEntity(characterArchetype)
        }

        let rig = try JockAnimationLibraryLoader.loadRigDefinition()
        let map = try JockAnimationLibraryLoader.loadSkeletonMap()
        let manifest = try JockAnimationLibraryLoader.loadManifest()
        let overrides = JockAnimationLibraryLoader.loadRuntimeClipOverridesIfAvailable()

        let runtimeApprovedSummaries = manifest.clips.filter { $0.approvedForRuntime }

        var loadedClips: [String: JockAnimClip] = [:]

        for summary in runtimeApprovedSummaries {
            let clip = try JockAnimationLibraryLoader.loadClip(summary: summary)
            loadedClips[clip.clipID] = clip
        }

        if loadedClips["dead_fall_forward"] == nil,
           let fallbackDeathClip = loadedClips["dead_fall_forward_01"] {
            loadedClips["dead_fall_forward"] = fallbackDeathClip
            print("[Gravitas Hit] Runtime alias registered: dead_fall_forward -> dead_fall_forward_01")
        }

        let requiredLoopIDs = JockPacingLoopStep.gravitasPresenceLoop.map(\.clipID)
        let missingLoopIDs = requiredLoopIDs.filter { loadedClips[$0] == nil }

        if missingLoopIDs.isEmpty {
            print("[Gravitas JockAsset Loop] All required loop clips loaded.")
        } else {
            print("[Gravitas JockAsset Loop] Missing required clips: \(missingLoopIDs.joined(separator: ", "))")
        }

        let requiredHitClips = [
            "hit_medium_left_01",
            "hit_medium_left_02",
            "hit_medium_right_01",
            "hit_medium_right_02",
            "hit_hard_left_01",
            "hit_hard_right_01",
            "dead_fall_forward",
            "dead_fall_backward_01",
            "dead_fall_backward_02"
        ]

        let missingHitClips = requiredHitClips.filter { loadedClips[$0] == nil }

        if missingHitClips.isEmpty {
            print("[Gravitas Hit] All phase-1 hit clips loaded.")
        } else {
            print("[Gravitas Hit] Missing phase-1 hit clips: \(missingHitClips.joined(separator: ", "))")
        }

        let missingHeadSnapSides = hitConfiguration.headSnapSubAnimationBySide
            .compactMap { side, candidateIDs -> String? in
                let hasAvailableSubAnimation = candidateIDs.contains { clipID in
                    loadedClips[clipID]?.isSubAnimationOverride == true
                }

                guard !hasAvailableSubAnimation else {
                    return nil
                }

                return "\(side.rawValue): \(candidateIDs.joined(separator: ", "))"
            }

        if missingHeadSnapSides.isEmpty {
            print("[Gravitas SubAnim] All phase-1 head snap sub-animations loaded.")
        } else {
            print("[Gravitas SubAnim] Missing or invalid head snap sub-animations: \(missingHeadSnapSides.joined(separator: " | "))")
        }

        let requiredAttackClipIDs = [
            "charged-slash-left",
            "charged-slash-right"
        ]

        let missingAttackClips = requiredAttackClipIDs.filter { clipID in
            loadedClips[clipID] == nil
        }

        if missingAttackClips.isEmpty {
            print("[Gravitas Attack] All phase-one attack clips loaded.")
        } else {
            print("[Gravitas Attack] Missing attack clips: \(missingAttackClips.joined(separator: ", "))")
        }

        let adapter = JockSkeletonAdapter(
            rig: rig,
            skeletonMap: map,
            runtimeJointNames: skinnedModel.jointNames
        )

        JockSkeletonAdapter.validateMappingRecords(
            adapter.mappingRecords,
            archetype: characterArchetype
        )

        if !adapter.validationReport.missingCanonicalJoints.isEmpty {
            throw RetargetError.rigValidationFailed(
                adapter.validationReport.missingCanonicalJoints
            )
        }

        let driver = JockRuntimeDriver(
            modelEntity: skinnedModel,
            adapter: adapter,
            characterArchetype: characterArchetype,
            poseApplicationPolicy: characterArchetype.poseApplicationPolicy,
            locomotionRootEntity: rootEntity,
            visualOffsetEntity: visualOffsetEntity
        )

        driver.prewarmClips(Array(loadedClips.values))

        driver.onClipCompleted = { [weak self] completedClip in
            Task { @MainActor in
                self?.handleJockClipCompleted(completedClip)
            }
        }

        visualOffsetEntity.addChild(loadedEntity)

        self.characterEntity = loadedEntity
        self.modelEntity = skinnedModel
        self.rigDefinition = rig
        self.skeletonMap = map
        self.manifest = manifest
        self.clipsByID = loadedClips
        self.runtimeOverrides = overrides
        self.adapter = adapter
        self.driver = driver
        self.skeletonWorldPoseResolver = JockSkeletonWorldPoseResolver(
            rig: rig,
            adapter: adapter
        )
        self.hasLoaded = true

        validateHitClipsArePrewarmed()

        let strictAttackClipIDs = [
            "charged-slash-left",
            "charged-slash-right"
        ]

        let loadedAttackIDs = strictAttackClipIDs.filter { clipID in
            clipsByID[clipID] != nil
        }

        print(
            """
            [Gravitas Attack] Strict attack clip load check
              required: \(strictAttackClipIDs.joined(separator: ", "))
              loaded: \(loadedAttackIDs.joined(separator: ", "))
              allClipIDsCount: \(clipsByID.keys.count)
            """
        )

        debugStatus = """
        JockAsset Retarget Test loaded.
        Character: \(characterArchetype.displayName)
        Asset: \(characterArchetype.usdzFileName)
        Runtime joints: \(skinnedModel.jointNames.count)
        Matched joints: \(adapter.validationReport.matchedJointCount)
        Library clips: \(loadedClips.count)
        """

        print("[Gravitas] \(debugStatus)")
    }

    private func validateHitClipsArePrewarmed() {
        let expectedHitClipIDs = Set(
            hitConfiguration.clipBuckets.values.flatMap { $0 } +
            hitConfiguration.deathClipIDs +
            hitConfiguration.headSnapSubAnimationBySide.values.flatMap { $0 } +
            [
                "charged-slash-left",
                "charged-slash-right"
            ]
        )

        let loadedClipIDs = Set(clipsByID.keys)
        let missingClipIDs = expectedHitClipIDs.filter { !loadedClipIDs.contains($0) }

        if missingClipIDs.isEmpty {
            print("[Gravitas Prewarm] All hit/sub-animation clips loaded.")
        } else {
            print("[Gravitas Prewarm] Missing hit/sub-animation clips: \(missingClipIDs.sorted().joined(separator: ", "))")
        }
    }

    func configureSpawn(
        using spawnPose: PhaseOneSpawnPose,
        floorY: Float
    ) {
        let configuration = PhaseOneConfiguration.phaseOneDefault
        let headForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(spawnPose.headForward.x, 0, spawnPose.headForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        spawnPosition = SIMD3<Float>(
            spawnPose.headPosition.x + headForward.x * configuration.farDistance,
            floorY,
            spawnPose.headPosition.z + headForward.z * configuration.farDistance
        )

        rootYawRadians = PhaseOneMath.normalizedAngleRadians(
            PhaseOneMath.yawRadiansForNegativeZForward(
                worldForward: headForward
            ) + configuration.visualYawCorrectionRadians
        )

        spawnOrientation = simd_quatf(
            angle: rootYawRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        cameraFacingVisualOffset = simd_quatf(
            angle: configuration.visualYawCorrectionRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        loopStartVisualOffset = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )

        resetRootToDefaultSpawn()

        logHeadHitZoneBuildIfNeeded()
    }

    func configureHordeSpawn(
        position: SIMD3<Float>,
        playerHeadPosition: SIMD3<Float>
    ) {
        let configuration = PhaseOneConfiguration.phaseOneDefault

        spawnPosition = position

        let enemyDirectionFromPlayer = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(
                position.x - playerHeadPosition.x,
                0,
                position.z - playerHeadPosition.z
            ),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        rootYawRadians = PhaseOneMath.normalizedAngleRadians(
            PhaseOneMath.yawRadiansForNegativeZForward(
                worldForward: enemyDirectionFromPlayer
            ) + configuration.visualYawCorrectionRadians
        )

        spawnOrientation = simd_quatf(
            angle: rootYawRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        cameraFacingVisualOffset = simd_quatf(
            angle: configuration.visualYawCorrectionRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        loopStartVisualOffset = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )

        resetRootToDefaultSpawn()
    }

    func configureHordeIdentity(
        id: UUID,
        archetype: PlagueCharacterArchetype,
        wave: Int,
        spawnIndex: Int,
        hitsToKill: Int
    ) {
        characterArchetype = archetype
        hordeID = id
        hordeWave = wave
        hordeSpawnIndex = spawnIndex
        self.hitsToKill = max(1, hitsToKill)
        lifecycleState = .alive
        activeDeathClipID = nil
        acceptedHitCount = 0
        hasLoggedHeadHitZoneBuild = false
        hasLoggedMissingHeadHitZone = false

        rootEntity.name = "Horde_\(archetype.rawValue)_wave\(wave)_index\(spawnIndex)_\(id.uuidString.prefix(6))"

        print(
            """
            [EnemySpawner] configured horde enemy instance
              id: \(id)
              archetype: \(archetype.rawValue)
              wave: \(wave)
              index: \(spawnIndex)
              hitsToKill: \(self.hitsToKill)
              entityName: \(rootEntity.name)
            """
        )
    }

    func show() {
        isVisible = true
        rootEntity.isEnabled = true
    }

    func hide() {
        isVisible = false
        isPlayingPacingLoop = false
        followDemoState = .inactive
        lifecycleState = .despawned
        activeDeathClipID = nil
        resetCombatRuntime()
        resetHitSelectionMemory()
        followDelayElapsed = 0
        latestHeadPosition = nil
        driver?.locomotionDeltaHandler = nil
        driver?.stop()
        hitDetector.stop()
        rootEntity.isEnabled = false
    }

    func playClip(id: String, loop: Bool) throws {
        show()
        isPlayingPacingLoop = false
        followDemoState = .inactive
        resetCombatRuntime()
        resetHitSelectionMemory()
        followDelayElapsed = 0
        driver?.locomotionDeltaHandler = nil
        hitDetector.stop()

        guard let clip = clipsByID[id] else {
            throw RetargetError.clipNotFound(id)
        }

        driver?.resetPoseImmediate(
            visualOffset: cameraFacingVisualOffset
        )

        resetRootToDefaultSpawn()

        driver?.playClip(
            clip,
            loop: loop,
            transition: true,
            runtimeOverride: cameraFacingRuntimeOverride()
        )
    }

    func playPacingLoopFromStart() throws {
        show()
        followDemoState = .inactive
        resetCombatRuntime()
        resetHitSelectionMemory()
        followDelayElapsed = 0
        driver?.locomotionDeltaHandler = nil
        hitDetector.stop()

        let requiredIDs = pacingLoopSteps.map(\.clipID)
        let missing = requiredIDs.filter { clipsByID[$0] == nil }

        if !missing.isEmpty {
            throw RetargetError.pacingLoopMissingClips(missing)
        }

        isPlayingPacingLoop = true
        pacingLoopIndex = 0

        driver?.resetPoseImmediate(
            visualOffset: loopStartVisualOffset
        )
        resetRootToLoopSpawn()

        playCurrentPacingLoopStep()
    }

    func stopClip() {
        isPlayingPacingLoop = false
        followDemoState = .inactive
        resetCombatRuntime()
        resetHitSelectionMemory()
        followDelayElapsed = 0
        latestHeadPosition = nil
        driver?.locomotionDeltaHandler = nil
        driver?.stop()
        hitDetector.stop()
    }

    func resetPose() {
        isPlayingPacingLoop = false
        followDemoState = .inactive
        resetCombatRuntime()
        resetHitSelectionMemory()
        followDelayElapsed = 0
        driver?.locomotionDeltaHandler = nil
        hitDetector.stop()
        resetRootToDefaultSpawn()
        driver?.resetPoseWithTransition(
            visualOffset: cameraFacingVisualOffset
        )
    }

    func playFollowDemo(
        resetBenchmarkState: Bool = true
    ) throws {
        show()

        lifecycleState = .alive
        activeDeathClipID = nil
        isPlayingPacingLoop = false
        followDemoState = .idleStopped
        followDelayElapsed = 0
        playerAttackEnabled = true
        resetCombatRuntime()
        resetHitSelectionMemory()

        if resetBenchmarkState {
            resetBenchmarkPlayerStateForNewRun()
        } else {
            benchmarkCurrentWave = hordeWave
            benchmarkPlayerHitsThisWave = 0
            isBenchmarkPlayerDead = false
        }

        guard clipsByID[followConfiguration.idleClipID] != nil else {
            throw RetargetError.clipNotFound(followConfiguration.idleClipID)
        }

        guard clipsByID[followConfiguration.walkClipID] != nil else {
            throw RetargetError.clipNotFound(followConfiguration.walkClipID)
        }

        driver?.locomotionDeltaHandler = { [weak self] delta in
            self?.consumeFollowLocomotionDelta(delta) ?? true
        }

        Task {
            await hitDetector.startIfNeeded()
        }

        playFollowIdle()

        print(
            """
            [Gravitas Follow] Follow demo started
              idleClip: \(followConfiguration.idleClipID)
              walkClip: \(followConfiguration.walkClipID)
              stopDistance: \(followConfiguration.stopDistanceMeters)
              resumeDistance: \(followConfiguration.resumeDistanceMeters)
              faceHits: enabled
            """
        )
    }

    func stopFollowDemo() {
        followDemoState = .inactive
        followDelayElapsed = 0
        latestHeadPosition = nil
        resetCombatRuntime()
        resetHitSelectionMemory()

        driver?.locomotionDeltaHandler = nil
        driver?.stop()
        hitDetector.stop()

        print("[Gravitas Follow] Follow demo stopped")
    }

    func stopForBenchmarkPlayerDeath() {
        isVisible = false
        rootEntity.isEnabled = false
        playerAttackEnabled = false
        lifecycleState = .despawned
        activeDeathClipID = nil
        followDemoState = .inactive
        followDelayElapsed = 0
        activeAttack = nil
        combatState = .normal
        isPlayingPacingLoop = false

        driver?.locomotionDeltaHandler = nil
        driver?.stop()
        hitDetector.stop()

        print("[HordeBenchmark] Enemy gameplay suspended for player death.")
    }

    func setPlayerAttackEnabled(_ enabled: Bool) {
        playerAttackEnabled = enabled

        print(
            """
            [PlayerAttack] enabled changed
              enabled: \(enabled)
            """
        )
    }

    func setBenchmarkPlayerDead(_ isDead: Bool) {
        isBenchmarkPlayerDead = isDead

        if isDead {
            playerAttackEnabled = false
        }
    }

    func update(
        deltaTime: Float,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard isVisible else { return }

        latestHeadPosition = currentHeadPosition
        let dt = TimeInterval(deltaTime)

        if followDemoState != .inactive {
            updateAttackMode(
                deltaTime: dt,
                currentHeadPosition: currentHeadPosition
            )
        }

        if canUpdateFollowMovement {
            updateFollowDemoIfNeeded(
                deltaTime: dt,
                currentHeadPosition: currentHeadPosition
            )
        }

        driver?.update(deltaTime: dt)

        if followDemoState != .inactive,
           playerAttackEnabled,
           !isInNonInterruptibleCombatState,
           currentHeadPosition != nil {
            updateHitDetectionIfNeeded(
                currentTime: Date().timeIntervalSinceReferenceDate
            )
        }

        updateAttackDamageDetectionIfNeeded(
            deltaTime: dt,
            currentHeadPosition: currentHeadPosition
        )
    }

    private func handleJockClipCompleted(_ completedClip: JockAnimClip) {
        if case .attacking = combatState,
           completedClip.clipID == activeAttack?.clipID {
            handleAttackCompleted(completedClip)
            return
        }

        switch combatState {
        case .dead where lifecycleState == .dying &&
            completedClip.clipID == activeDeathClipID:
            finishBenchmarkEnemyDeathAnimation(
                completedClip: completedClip
            )

        case .hitReaction(let clipID, let damage):
            guard completedClip.clipID == clipID else {
                return
            }

            handleHitReactionCompleted(
                clipID: clipID,
                damage: damage
            )

        case .dead:
            return

        case .normal, .closeRangeReady, .attacking:
            handleClipCompleted(completedClip)
        }
    }

    private func handleHitReactionCompleted(
        clipID: String,
        damage: JockHitDamageLevel
    ) {
        print(
            """
            [Gravitas Hit] Hit reaction completed
              clipID: \(clipID)
              damage: \(damage.rawValue)
              escalateAfterHitReact: \(escalateAfterHitReact)
            """
        )

        guard followDemoState != .inactive else {
            combatState = .normal
            escalateAfterHitReact = false
            return
        }

        let shouldEscalate = escalateAfterHitReact
        escalateAfterHitReact = false

        if shouldEscalate,
           let latestHeadPosition {
            let distance = horizontalDistanceToUser(
                headPosition: latestHeadPosition
            )

            if distance <= attackConfiguration.attackProximityMeters {
                let delay = attackConfiguration.randomAggressiveDelay()
                playFollowIdle(allowDuringCombat: true)
                combatState = .closeRangeReady(delayRemaining: delay)

                print("[Gravitas Attack] Escalating after hit reaction at close range.")
                return
            }
        }

        combatState = .normal

        driver?.locomotionDeltaHandler = { [weak self] delta in
            self?.consumeFollowLocomotionDelta(delta) ?? true
        }

        followDemoState = .idleStopped
        followDelayElapsed = 0
        playFollowIdle()
    }

    private func handleClipCompleted(_ completedClip: JockAnimClip) {
        guard isPlayingPacingLoop else { return }

        print("[Gravitas JockAsset Loop] Completed clip: \(completedClip.clipID)")

        pacingLoopIndex = (pacingLoopIndex + 1) % pacingLoopSteps.count
        playCurrentPacingLoopStep()
    }

    private func updateHitDetectionIfNeeded(
        currentTime: TimeInterval
    ) {
        let faceCenter: SIMD3<Float>
        let diagnosticHeadRadius: Float?

        if characterArchetype == .dad {
            faceCenter = estimatedCharacterFaceCenterWorldPosition()
            diagnosticHeadRadius = nil
        } else if let headHitZone = currentHeadHitZone() {
            faceCenter = headHitZone.centerWorld
            diagnosticHeadRadius = headHitZone.radiusMeters

            logHeadHitZoneBuildIfNeeded(
                headHitZone
            )
        } else {
            logMissingHeadHitZoneIfNeeded()
            return
        }

        guard let event = hitDetector.update(
            currentTime: currentTime,
            characterRoot: rootEntity,
            faceCenterWorld: faceCenter,
            headHitRadiusMeters: diagnosticHeadRadius
        ) else {
            return
        }

        handleHitEvent(event)
    }

    private func estimatedCharacterFaceCenterWorldPosition() -> SIMD3<Float> {
        let localFaceCenter = SIMD3<Float>(
            0,
            hitConfiguration.faceCenterHeightMeters,
            -0.04
        )

        return rootEntity.position + rootEntity.orientation.act(localFaceCenter)
    }

    private func currentHeadHitZone() -> InfectedHeadHitZone? {
        guard let driver,
              let modelEntity,
              let skeletonWorldPoseResolver else {
            return nil
        }

        let headWorld = skeletonWorldPoseResolver.worldPosition(
            for: "Head",
            jointTransforms: driver.currentJointTransforms,
            modelEntity: modelEntity
        )

        let headEndWorld = skeletonWorldPoseResolver.worldPosition(
            for: "head_end",
            jointTransforms: driver.currentJointTransforms,
            modelEntity: modelEntity
        )

        let headFrontWorld = skeletonWorldPoseResolver.worldPosition(
            for: "headfront",
            jointTransforms: driver.currentJointTransforms,
            modelEntity: modelEntity
        )

        guard let headWorld else {
            return nil
        }

        let centerWorld: SIMD3<Float>
        let jointDescription: String

        if let headEndWorld {
            centerWorld = (headWorld + headEndWorld) * 0.5
            jointDescription = "Head/head_end"
        } else {
            centerWorld = headWorld
            jointDescription = "Head"
        }

        return InfectedHeadHitZone(
            centerWorld: centerWorld,
            radiusMeters: estimatedHeadHitRadius(
                headWorld: headWorld,
                headEndWorld: headEndWorld,
                headFrontWorld: headFrontWorld
            ),
            jointDescription: jointDescription,
            headWorld: headWorld,
            headEndWorld: headEndWorld,
            headFrontWorld: headFrontWorld
        )
    }

    private func estimatedHeadHitRadius(
        headWorld: SIMD3<Float>,
        headEndWorld: SIMD3<Float>?,
        headFrontWorld: SIMD3<Float>?
    ) -> Float {
        if let headEndWorld {
            let distance = simd_distance(headWorld, headEndWorld)

            if distance.isFinite, distance > 0.01 {
                return min(
                    max(distance * 1.05, 0.12),
                    0.30
                )
            }
        }

        if let headFrontWorld {
            let distance = simd_distance(headWorld, headFrontWorld)

            if distance.isFinite, distance > 0.01 {
                return min(
                    max(distance * 2.0, 0.12),
                    0.30
                )
            }
        }

        switch characterArchetype {
        case .dad:
            return 0.18

        case .neighbor:
            return 0.22

        case .spouse:
            return 0.18

        case .biker:
            return 0.20
        }
    }

    private func logHeadHitZoneBuildIfNeeded(
        _ zone: InfectedHeadHitZone? = nil
    ) {
        guard !hasLoggedHeadHitZoneBuild else {
            return
        }

        guard let zone = zone ?? currentHeadHitZone() else {
            logMissingHeadHitZoneIfNeeded()
            return
        }

        hasLoggedHeadHitZoneBuild = true

        print(
            """
            [InfectedHitZone] built head hit zone
              enemyID: \(hordeID)
              archetype: \(characterArchetype.rawValue)
              joint: \(zone.jointDescription)
              radius: \(zone.radiusMeters)
              centerWorld: \(zone.centerWorld)
              headWorld: \(zone.headWorld.map { String(describing: $0) } ?? "nil")
              headEndWorld: \(zone.headEndWorld.map { String(describing: $0) } ?? "nil")
              headFrontWorld: \(zone.headFrontWorld.map { String(describing: $0) } ?? "nil")
              parent: \(rootEntity.name)
            """
        )
    }

    private func logMissingHeadHitZoneIfNeeded() {
        guard !hasLoggedMissingHeadHitZone else {
            return
        }

        hasLoggedMissingHeadHitZone = true

        print(
            """
            [InfectedHitZone] ERROR no head joint found
              enemyID: \(hordeID)
              archetype: \(characterArchetype.rawValue)
              availableJoints: \(adapter?.runtimeJointNames.joined(separator: ", ") ?? "nil")
            """
        )
    }

    private func handleHitEvent(
        _ event: JockHandHitDetector.HitEvent
    ) {
        guard followDemoState != .inactive else { return }

        guard lifecycleState == .alive else {
            print(
                """
                [InfectedDamage] ignored hit
                  id: \(hordeID)
                  state: \(lifecycleState.rawValue)
                """
            )
            return
        }

        if case .hitReaction = combatState {
            return
        }

        if case .dead = combatState {
            return
        }

        if event.region == .head {
            print(
                """
                [PlayerAttack] HEAD HIT
                  enemyID: \(hordeID)
                  archetype: \(characterArchetype.rawValue)
                  wave: \(hordeWave)
                  spawnIndex: \(hordeSpawnIndex)
                """
            )
        }

        acceptedHitCount += 1
        onPunchHit?()

        let shouldDie = acceptedHitCount >= hitsToKill
        let finalDamage: JockHitDamageLevel = shouldDie
            ? .death
            : event.damageLevel
        let isStrongHit = attackConfiguration.escalationDamageLevels.contains(finalDamage)
        let authoredClipSide = authoredHitClipSide(
            forDetectedFaceSide: event.side
        )
        let selectedClipID: String?

        if isStrongHit {
            escalateAfterHitReact = true
        }

        if case .attacking = combatState {
            cancelActiveAttackForPlayerHit(
                isStrongHit: isStrongHit
            )
        }

        triggerHeadSnapSubAnimation(for: event.side)

        if shouldDie {
            selectedClipID = randomAvailableClipID(
                from: hitConfiguration.deathClipIDs,
                avoidRepeatKey: "death"
            )
        } else {
            selectedClipID = selectHitClipID(
                side: authoredClipSide,
                damage: finalDamage
            )
        }

        followDemoState = .idleStopped
        followDelayElapsed = 0

        driver?.locomotionDeltaHandler = nil

        print(
            """
            [Gravitas Hit] Registered face hit
              hitCount: \(acceptedHitCount)
              hand: \(event.hand)
              region: \(event.region.rawValue)
              deterministicSide: \(event.side.rawValue)
              authoredClipSide: \(authoredClipSide.rawValue)
              classifiedDamage: \(event.damageLevel.rawValue)
              finalDamage: \(finalDamage.rawValue)
              isStrongHit: \(isStrongHit)
              velocity: \(String(format: "%.2f", event.velocityMetersPerSecond)) m/s
              selectedClip: \(selectedClipID ?? "none")
              shouldDie: \(shouldDie)
              hordeID: \(hordeID)
              hordeWave: \(hordeWave)
              hordeSpawnIndex: \(hordeSpawnIndex)
              infectedHitsToKill: \(hitsToKill)
            """
        )

        applyHitKnockback(
            damage: finalDamage
        )

        if shouldDie {
            completeBenchmarkEnemyKill(
                selectedClipID: selectedClipID
            )
            return
        }

        guard let selectedClipID,
              let clip = clipsByID[selectedClipID] else {
            print("[Gravitas Hit] No valid hit clip found. Falling back to idle.")
            combatState = .normal
            activeAttack = nil
            playFollowIdle()
            return
        }

        activeAttack = nil
        combatState = .hitReaction(
            clipID: selectedClipID,
            damage: finalDamage
        )

        driver?.playClip(
            clip,
            loop: false,
            transition: true,
            locomotionPolicy: .ignoreClipLocomotion,
            runtimeOverride: followVisualRuntimeOverride()
        )
    }

    private func completeBenchmarkEnemyKill(
        selectedClipID: String?
    ) {
        let killedID = hordeID
        let killedWave = hordeWave

        guard lifecycleState == .alive else {
            print(
                """
                [InfectedDeath] duplicate begin ignored
                  id: \(killedID)
                  state: \(lifecycleState.rawValue)
                """
            )
            return
        }

        lifecycleState = .dying
        activeDeathClipID = selectedClipID
        combatState = .dead
        activeAttack = nil
        followDemoState = .inactive
        followDelayElapsed = 0
        isPlayingPacingLoop = false
        playerAttackEnabled = false

        driver?.locomotionDeltaHandler = nil
        hitDetector.stop()

        print(
            """
            [InfectedDeath] death animation started
              enemyID: \(killedID)
              hordeID: \(killedID)
              wave: \(killedWave)
              index: \(hordeSpawnIndex)
              hits: \(acceptedHitCount)/\(hitsToKill)
              selectedClip: \(selectedClipID ?? "none")
              corpseWillRemainUntilWaveEnd: true
            """
        )

        onBenchmarkEnemyKilled?(
            killedID,
            killedWave
        )

        guard let selectedClipID,
              let clip = clipsByID[selectedClipID] else {
            print("[InfectedDeath] No death clip available. Settling corpse immediately.")
            finishBenchmarkEnemyDeathAnimation(
                completedClip: nil
            )
            return
        }

        activeDeathClipID = clip.clipID

        driver?.playClip(
            clip,
            loop: false,
            transition: true,
            locomotionPolicy: .ignoreClipLocomotion,
            runtimeOverride: followVisualRuntimeOverride()
        )
    }

    private func finishBenchmarkEnemyDeathAnimation(
        completedClip: JockAnimClip?
    ) {
        guard lifecycleState == .dying else {
            print(
                """
                [InfectedDeath] finish ignored
                  id: \(hordeID)
                  state: \(lifecycleState.rawValue)
                """
            )
            return
        }

        lifecycleState = .corpse
        activeDeathClipID = nil
        combatState = .dead
        followDemoState = .inactive
        followDelayElapsed = 0
        activeAttack = nil
        isPlayingPacingLoop = false
        playerAttackEnabled = false
        driver?.locomotionDeltaHandler = nil
        hitDetector.stop()

        onBenchmarkEnemyDeathAnimationFinished?(
            hordeID,
            hordeWave
        )

        print(
            """
            [InfectedDeath] corpse settled
              enemyID: \(hordeID)
              hordeID: \(hordeID)
              wave: \(hordeWave)
              deathClip: \(completedClip?.clipID ?? "none")
              entityStillInScene: \(rootEntity.parent != nil)
            """
        )
    }

    private func cancelActiveAttackForPlayerHit(
        isStrongHit: Bool
    ) {
        guard var attack = activeAttack else { return }

        attack.wasCanceled = true
        activeAttack = attack

        print(
            """
            [Gravitas Attack] Active attack canceled by player hit
              strongHit: \(isStrongHit)
              clipID: \(attack.clipID)
            """
        )
    }

    private func selectHeadSnapSubAnimationClipID(
        for side: JockHitSide
    ) -> String? {
        let candidateIDs = hitConfiguration.headSnapSubAnimationBySide[side] ?? []

        let available = candidateIDs.filter { clipID in
            guard let clip = clipsByID[clipID] else {
                return false
            }

            return clip.isSubAnimationOverride
        }

        guard !available.isEmpty else {
            print(
                """
                [Gravitas SubAnim] No head snap sub-animation available
                  deterministicSide: \(side.rawValue)
                  candidates: \(candidateIDs.joined(separator: ", "))
                """
            )
            return nil
        }

        return available.randomElement()
    }

    private func triggerHeadSnapSubAnimation(
        for side: JockHitSide
    ) {
        guard let clipID = selectHeadSnapSubAnimationClipID(for: side),
              let clip = clipsByID[clipID] else {
            return
        }

        driver?.triggerSubAnimation(clip)

        print(
            """
            [Gravitas Hit] Triggered head snap sub-animation
              deterministicSide: \(side.rawValue)
              clipID: \(clipID)
            """
        )
    }

    private func authoredHitClipSide(
        forDetectedFaceSide detectedSide: JockHitSide
    ) -> JockHitSide {
        hitConfiguration.invertHitClipSide
            ? detectedSide.opposite
            : detectedSide
    }

    private func selectHitClipID(
        side: JockHitSide,
        damage: JockHitDamageLevel
    ) -> String? {
        let candidateIDs = hitClipCandidates(
            side: side,
            damage: damage
        )

        let bucketKey = "\(side.rawValue)_\(damage.rawValue)"

        let selected = randomAvailableClipID(
            from: candidateIDs,
            avoidRepeatKey: bucketKey
        )

        print(
            """
            [Gravitas Hit] Clip selection
              side: \(side.rawValue)
              damage: \(damage.rawValue)
              candidates: \(candidateIDs.joined(separator: ", "))
              available: \(candidateIDs.filter { clipsByID[$0] != nil }.joined(separator: ", "))
              selected: \(selected ?? "none")
            """
        )

        if let selected {
            lastHitClipIDBySide[side] = selected
        }

        return selected
    }

    private func hitClipCandidates(
        side: JockHitSide,
        damage: JockHitDamageLevel
    ) -> [String] {
        if damage == .death {
            return hitConfiguration.deathClipIDs
        }

        let damageLevels: [JockHitDamageLevel]

        if hitConfiguration.includeLowerDamageClipsForHigherDamage {
            damageLevels = JockHitDamageLevel.allCases
                .filter { $0 != .death && $0.rank <= damage.rank }
                .sorted { $0.rank > $1.rank }
        } else {
            damageLevels = [damage]
        }

        var candidates: [String] = []

        for level in damageLevels {
            let key = JockHitBucketKey(
                side: side,
                damageLevel: level
            )

            candidates.append(
                contentsOf: hitConfiguration.clipBuckets[key] ?? []
            )
        }

        if candidates.isEmpty {
            let mediumKey = JockHitBucketKey(
                side: side,
                damageLevel: .medium
            )

            candidates.append(
                contentsOf: hitConfiguration.clipBuckets[mediumKey] ?? []
            )
        }

        if candidates.isEmpty {
            let oppositeSide: JockHitSide = side == .left ? .right : .left
            let oppositeMediumKey = JockHitBucketKey(
                side: oppositeSide,
                damageLevel: .medium
            )

            candidates.append(
                contentsOf: hitConfiguration.clipBuckets[oppositeMediumKey] ?? []
            )
        }

        return deduplicated(candidates)
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(value)
        }

        return result
    }

    private func randomAvailableClipID(
        from candidateIDs: [String],
        avoidRepeatKey: String
    ) -> String? {
        let available = candidateIDs.filter { clipsByID[$0] != nil }

        if available.count != candidateIDs.count {
            let missing = candidateIDs.filter { clipsByID[$0] == nil }

            if !missing.isEmpty {
                print("[Gravitas Hit] Skipping missing hit clips: \(missing.joined(separator: ", "))")
            }
        }

        guard !available.isEmpty else {
            return nil
        }

        if hitConfiguration.avoidImmediateRepeat,
           let last = lastHitClipIDByBucket[avoidRepeatKey],
           available.count > 1 {
            let nonRepeats = available.filter { $0 != last }

            if let selected = nonRepeats.randomElement() {
                lastHitClipIDByBucket[avoidRepeatKey] = selected
                return selected
            }
        }

        let selected = available.randomElement()

        if let selected {
            lastHitClipIDByBucket[avoidRepeatKey] = selected
        }

        return selected
    }

    private func applyHitKnockback(
        damage: JockHitDamageLevel
    ) {
        let knockback = hitConfiguration.knockbackMeters(for: damage)

        guard knockback > 0 else { return }

        let awayFromUser: SIMD3<Float>

        if let latestHeadPosition {
            let raw = SIMD3<Float>(
                rootEntity.position.x - latestHeadPosition.x,
                0,
                rootEntity.position.z - latestHeadPosition.z
            )

            awayFromUser = PhaseOneMath.normalizedOrFallback(
                raw,
                fallback: rootEntity.orientation.act(SIMD3<Float>(0, 0, 1))
            )
        } else {
            awayFromUser = rootEntity.orientation.act(SIMD3<Float>(0, 0, 1))
        }

        rootEntity.position += awayFromUser * knockback
    }

    private func updateAttackMode(
        deltaTime: TimeInterval,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard attackConfiguration.enabled else { return }
        guard let currentHeadPosition else { return }

        switch combatState {
        case .dead, .hitReaction:
            return

        case .attacking:
            if var attack = activeAttack {
                attack.elapsedSeconds += deltaTime
                activeAttack = attack
            }
            return

        case .closeRangeReady(let delayRemaining):
            let distance = horizontalDistanceToUser(
                headPosition: currentHeadPosition
            )

            if distance > attackConfiguration.resumeFollowDistanceMeters {
                exitCloseRangeToFollow()
                return
            }

            let nextDelay = delayRemaining - deltaTime

            if nextDelay <= 0 {
                startAttackIfPossible()
            } else {
                combatState = .closeRangeReady(delayRemaining: nextDelay)
            }

        case .normal:
            let distance = horizontalDistanceToUser(
                headPosition: currentHeadPosition
            )

            if distance <= attackConfiguration.attackProximityMeters {
                enterCloseRangeReady()
            }
        }
    }

    private func enterCloseRangeReady() {
        guard followDemoState != .inactive else { return }

        driver?.locomotionDeltaHandler = nil

        followDemoState = .idleStopped
        followDelayElapsed = 0

        playFollowIdle(allowDuringCombat: true)

        let delay = attackConfiguration.randomAggressiveDelay()

        combatState = .closeRangeReady(
            delayRemaining: delay
        )

        print(
            """
            [Gravitas Attack] Entered CloseRangeReady
              delay: \(String(format: "%.3f", delay))
              proximity: \(attackConfiguration.attackProximityMeters)
            """
        )
    }

    private func exitCloseRangeToFollow() {
        activeAttack = nil
        combatState = .normal
        followDemoState = .waitingToFollow
        followDelayElapsed = 0

        driver?.locomotionDeltaHandler = { [weak self] delta in
            self?.consumeFollowLocomotionDelta(delta) ?? true
        }

        print("[Gravitas Attack] Player moved out of close range. Returning to follow.")
    }

    private func startAttackIfPossible() {
        guard followDemoState != .inactive else { return }

        // HARD STOP: attack selection is ONLY these two IDs.
        let attackIDs = [
            "charged-slash-left",
            "charged-slash-right"
        ]

        guard let leftClip = clipsByID["charged-slash-left"] else {
            assertionFailure("[Gravitas Attack] Missing REQUIRED clip: charged-slash-left")
            print("[Gravitas Attack] ERROR missing REQUIRED clip: charged-slash-left")
            return
        }

        guard let rightClip = clipsByID["charged-slash-right"] else {
            assertionFailure("[Gravitas Attack] Missing REQUIRED clip: charged-slash-right")
            print("[Gravitas Attack] ERROR missing REQUIRED clip: charged-slash-right")
            return
        }

        let attackClip: JockAnimClip = Bool.random() ? leftClip : rightClip

        print(
            """
            [Gravitas Attack] TWO-CLIP ONLY RANDOM SELECT
              candidates: \(attackIDs.joined(separator: ", "))
              selected: \(attackClip.clipID)
            """
        )

        let metadata = attackClip.resolvedAttackMetadata()

        activeAttack = JockActiveAttackState(
            clipID: attackClip.clipID,
            metadata: metadata,
            elapsedSeconds: 0,
            hasDealtDamage: false,
            wasCanceled: false
        )

        combatState = .attacking

        driver?.locomotionDeltaHandler = nil

        onAttackStarted?()

        driver?.playClip(
            attackClip,
            loop: false,
            transition: true,
            locomotionPolicy: .ignoreClipLocomotion,
            runtimeOverride: followVisualRuntimeOverride()
        )

        print(
            """
            [Gravitas Attack] Started attack
              clipID: \(attackClip.clipID)
              joint: \(metadata.attackingJoint)
              window: \(metadata.attackWindowStartFrame)-\(metadata.attackWindowEndFrame)
              radius: \(metadata.damageRadiusMeters)
              damage: \(metadata.damageAmount)
            """
        )
    }

    private func handleAttackCompleted(_ completedClip: JockAnimClip) {
        print("[Gravitas Attack] Attack completed: \(completedClip.clipID)")

        activeAttack = nil

        guard followDemoState != .inactive else {
            combatState = .normal
            return
        }

        guard let latestHeadPosition else {
            combatState = .normal
            return
        }

        let distance = horizontalDistanceToUser(
            headPosition: latestHeadPosition
        )

        if distance <= attackConfiguration.resumeFollowDistanceMeters {
            let delay = attackConfiguration.randomAggressiveDelay()
            playFollowIdle(allowDuringCombat: true)
            combatState = .closeRangeReady(delayRemaining: delay)

            print(
                """
                [Gravitas Attack] Player still in attack band. Returning to CloseRangeReady.
                  distance: \(String(format: "%.3f", distance))
                  resumeFollowDistance: \(attackConfiguration.resumeFollowDistanceMeters)
                """
            )
        } else {
            exitCloseRangeToFollow()
        }
    }

    private func updateAttackDamageDetectionIfNeeded(
        deltaTime: TimeInterval,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard case .attacking = combatState else { return }
        guard var attack = activeAttack else { return }
        guard !attack.wasCanceled else { return }

        if attack.hasDealtDamage && attack.metadata.canDamageOncePerPlayback {
            return
        }

        guard let clip = clipsByID[attack.clipID] else { return }
        guard let driver else { return }

        if driver.currentActiveClipID == attack.clipID {
            attack.elapsedSeconds = driver.currentPlaybackTime
            activeAttack = attack
        }

        let fps = clip.timing.fps > 0
            ? clip.timing.fps
            : 24.0

        guard attack.isInsideDamageWindow(fps: fps) else {
            activeAttack = attack
            return
        }

        guard let currentHeadPosition else {
            activeAttack = attack
            return
        }

        guard let handWorldPosition = attackHandWorldPosition(
            jointName: attack.metadata.attackingJoint
        ) else {
            activeAttack = attack
            return
        }

        let dangerBoxCheck = playerDangerBoxCheck(
            handWorldPosition: handWorldPosition,
            headPosition: currentHeadPosition
        )

        guard dangerBoxCheck.isInside else {
            activeAttack = attack
            return
        }

        attack.hasDealtDamage = true
        activeAttack = attack

        applyPlayerDamage(
            amount: attack.metadata.damageAmount,
            handWorldPosition: handWorldPosition,
            distance: dangerBoxCheck.distanceToBox
        )
    }

    private func playerDangerBoxCheck(
        handWorldPosition: SIMD3<Float>,
        headPosition: SIMD3<Float>
    ) -> (isInside: Bool, distanceToBox: Float) {
        let halfWidth = attackConfiguration.playerDangerBoxWidthMeters * 0.5
        let halfDepth = attackConfiguration.playerDangerBoxDepthMeters * 0.5

        let topY = headPosition.y + attackConfiguration.playerDangerBoxTopOffsetMeters
        let bottomY = topY - attackConfiguration.playerDangerBoxHeightMeters

        let minPoint = SIMD3<Float>(
            headPosition.x - halfWidth,
            bottomY,
            headPosition.z - halfDepth
        )

        let maxPoint = SIMD3<Float>(
            headPosition.x + halfWidth,
            topY,
            headPosition.z + halfDepth
        )

        let isInside =
            handWorldPosition.x >= minPoint.x &&
            handWorldPosition.x <= maxPoint.x &&
            handWorldPosition.y >= minPoint.y &&
            handWorldPosition.y <= maxPoint.y &&
            handWorldPosition.z >= minPoint.z &&
            handWorldPosition.z <= maxPoint.z

        let closestPoint = SIMD3<Float>(
            min(max(handWorldPosition.x, minPoint.x), maxPoint.x),
            min(max(handWorldPosition.y, minPoint.y), maxPoint.y),
            min(max(handWorldPosition.z, minPoint.z), maxPoint.z)
        )

        return (
            isInside: isInside,
            distanceToBox: simd_distance(handWorldPosition, closestPoint)
        )
    }

    private func attackHandWorldPosition(
        jointName: String
    ) -> SIMD3<Float>? {
        guard let driver else { return nil }
        guard let modelEntity else { return nil }
        guard let skeletonWorldPoseResolver else { return nil }

        return skeletonWorldPoseResolver.worldPosition(
            for: jointName,
            jointTransforms: driver.currentJointTransforms,
            modelEntity: modelEntity
        )
    }

    private func applyPlayerDamage(
        amount: Int,
        handWorldPosition: SIMD3<Float>,
        distance: Float
    ) {
        guard !isBenchmarkPlayerDead else { return }

        playerExposure = min(
            attackConfiguration.exposureMax,
            playerExposure + amount
        )

        if let onBenchmarkPlayerHit,
           onBenchmarkPlayerHit(amount, hordeID) {
            isBenchmarkPlayerDead = true
            playerAttackEnabled = false

            print(
                """
                [Gravitas Damage] Player death hit accepted
                  amount: \(amount)
                  bodyBoxDistance: \(String(format: "%.3f", distance))
                  handWorldPosition: \(handWorldPosition)
                  attackerHordeID: \(hordeID)
                """
            )
            return
        }

        if onBenchmarkPlayerHit == nil,
           registerConfirmedBenchmarkPlayerHit() {
            print(
                """
                [Gravitas Damage] Player death hit accepted
                  amount: \(amount)
                  bodyBoxDistance: \(String(format: "%.3f", distance))
                  handWorldPosition: \(handWorldPosition)
                  attackerHordeID: \(hordeID)
                """
            )
            return
        }

        onPlayerDamaged?(amount)

        print(
            """
            [Gravitas Damage] Player damaged
              amount: \(amount)
              exposure: \(playerExposure)/\(attackConfiguration.exposureMax)
              bodyBoxDistance: \(String(format: "%.3f", distance))
              handWorldPosition: \(handWorldPosition)
            """
        )

        if playerExposure >= attackConfiguration.exposureMax {
            handlePlayerExposureMaxed()
        }
    }

    private func handlePlayerExposureMaxed() {
        print("[Gravitas Damage] Player exposure maxed.")

        if attackConfiguration.failOnExposureMax {
            stopFollowDemo()
        }
    }

    private func resetBenchmarkPlayerStateForNewRun() {
        benchmarkCurrentWave = max(hordeWave, 1)
        benchmarkPlayerHitsThisWave = 0
        isBenchmarkPlayerDead = false
        playerAttackEnabled = true
    }

    @discardableResult
    private func registerConfirmedBenchmarkPlayerHit() -> Bool {
        guard !isBenchmarkPlayerDead else { return true }

        if benchmarkCurrentWave <= 0 {
            benchmarkCurrentWave = max(hordeWave, 1)
            benchmarkPlayerHitsThisWave = 0
        }

        benchmarkPlayerHitsThisWave += 1

        print(
            """
            [HordeBenchmark] Player hit confirmed
              wave: \(benchmarkCurrentWave)
              hitsThisWave: \(benchmarkPlayerHitsThisWave)
              hitLimit: \(benchmarkPlayerHitLimitPerWave)
            """
        )

        guard benchmarkPlayerHitsThisWave >= benchmarkPlayerHitLimitPerWave else {
            return false
        }

        triggerBenchmarkPlayerDeath()
        return true
    }

    private func triggerBenchmarkPlayerDeath() {
        guard !isBenchmarkPlayerDead else { return }

        isBenchmarkPlayerDead = true
        playerAttackEnabled = false

        print(
            """
            [HordeBenchmark] Player death triggered
              wave: \(benchmarkCurrentWave)
              hitsThisWave: \(benchmarkPlayerHitsThisWave)
            """
        )

        onBenchmarkPlayerDeath?(
            benchmarkCurrentWave,
            benchmarkPlayerHitsThisWave
        )
    }

    private func playCurrentPacingLoopStep() {
        guard isPlayingPacingLoop else { return }
        guard !pacingLoopSteps.isEmpty else { return }

        let step = pacingLoopSteps[pacingLoopIndex]

        guard let clip = clipsByID[step.clipID] else {
            assertionFailure("Missing JockAsset pacing loop clip: \(step.clipID)")
            isPlayingPacingLoop = false
            return
        }

        print(
            """
            [Gravitas JockAsset Loop] Playing step
              index: \(pacingLoopIndex)
              clipID: \(step.clipID)
              displayName: \(clip.displayName)
              duration: \(String(format: "%.3f", clip.timing.durationSeconds))
              locomotionEnabled: \(clip.locomotion.isEnabled)
            """
        )

        driver?.playClip(
            clip,
            loop: step.loopClip,
            transition: true,
            locomotionPolicy: .useClipLocomotion,
            runtimeOverride: runtimeOverrides.clips[step.clipID] ?? .identity
        )
    }

    private func updateFollowDemoIfNeeded(
        deltaTime: TimeInterval,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard followDemoState != .inactive else {
            return
        }

        guard let currentHeadPosition else {
            return
        }

        let horizontalDistance = horizontalDistanceToUser(
            headPosition: currentHeadPosition
        )

        steerRootTowardUser(
            headPosition: currentHeadPosition,
            deltaTime: Float(deltaTime)
        )

        switch followDemoState {
        case .inactive:
            return

        case .idleStopped:
            if horizontalDistance > followConfiguration.resumeDistanceMeters {
                followDemoState = .waitingToFollow
                followDelayElapsed = 0
            }

        case .waitingToFollow:
            if horizontalDistance <= followConfiguration.stopDistanceMeters {
                followDemoState = .idleStopped
                followDelayElapsed = 0
                playFollowIdle()
                return
            }

            followDelayElapsed += deltaTime

            if followDelayElapsed >= followConfiguration.idleBeforeFollowDelay {
                followDemoState = .following
                playFollowWalk()
            }

        case .following:
            if horizontalDistance <= followConfiguration.stopDistanceMeters {
                followDemoState = .idleStopped
                followDelayElapsed = 0
                playFollowIdle()
            }
        }
    }

    private func horizontalDistanceToUser(
        headPosition: SIMD3<Float>
    ) -> Float {
        let root = rootEntity.position
        let delta = SIMD2<Float>(
            headPosition.x - root.x,
            headPosition.z - root.z
        )

        return simd_length(delta)
    }

    private func horizontalDirectionToUser(
        headPosition: SIMD3<Float>
    ) -> SIMD3<Float>? {
        let root = rootEntity.position

        let raw = SIMD3<Float>(
            headPosition.x - root.x,
            0,
            headPosition.z - root.z
        )

        let lengthSquared = simd_length_squared(raw)

        guard lengthSquared > 0.000001 else {
            return nil
        }

        return simd_normalize(raw)
    }

    private func steerRootTowardUser(
        headPosition: SIMD3<Float>,
        deltaTime: Float
    ) {
        guard let direction = horizontalDirectionToUser(
            headPosition: headPosition
        ) else {
            return
        }

        let targetYaw = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: direction
        )

        let currentForward = rootEntity.orientation.act(
            SIMD3<Float>(0, 0, -1)
        )

        let currentHorizontalForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(currentForward.x, 0, currentForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let currentYaw = PhaseOneMath.yawRadiansForNegativeZForward(
            worldForward: currentHorizontalForward
        )

        let deltaYaw = PhaseOneMath.normalizedAngleRadians(
            targetYaw - currentYaw
        )

        guard abs(deltaYaw) > followConfiguration.facingDeadZoneRadians else {
            return
        }

        let maxStep = followConfiguration.maxTurnRadiansPerSecond * deltaTime
        let clampedStep = min(max(deltaYaw, -maxStep), maxStep)
        let newYaw = currentYaw + clampedStep

        rootEntity.orientation = simd_quatf(
            angle: newYaw,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    private func playFollowIdle(
        allowDuringCombat: Bool = false
    ) {
        guard !isActionLocked || allowDuringCombat else {
            print("[Gravitas Follow] Ignored idle request because action is locked.")
            return
        }

        guard let clip = clipsByID[followConfiguration.idleClipID] else {
            assertionFailure("Missing follow idle clip: \(followConfiguration.idleClipID)")
            return
        }

        driver?.playClip(
            clip,
            loop: true,
            transition: true,
            locomotionPolicy: .useClipLocomotion,
            runtimeOverride: followVisualRuntimeOverride()
        )

        print("[Gravitas Follow] Playing idle")
    }

    private func playFollowWalk() {
        guard !isActionLocked else {
            print("[Gravitas Follow] Ignored walk request because action is locked.")
            return
        }

        guard let clip = clipsByID[followConfiguration.walkClipID] else {
            assertionFailure("Missing follow walk clip: \(followConfiguration.walkClipID)")
            return
        }

        driver?.playClip(
            clip,
            loop: true,
            transition: true,
            locomotionPolicy: .useClipLocomotion,
            runtimeOverride: followVisualRuntimeOverride()
        )

        print("[Gravitas Follow] Playing walk")
    }

    private func followVisualRuntimeOverride() -> JockRuntimeClipOverride {
        JockRuntimeClipOverride(
            entryHeadingDegrees: -followConfiguration.visualHeadingCorrectionDegrees,
            exitHeadingDegrees: -followConfiguration.visualHeadingCorrectionDegrees,
            commitRootYawOnCompletion: false
        )
    }

    private func cameraFacingRuntimeOverride() -> JockRuntimeClipOverride {
        let correctionDegrees =
            cameraFacingVisualOffset.angle * 180.0 / Float.pi

        return JockRuntimeClipOverride(
            entryHeadingDegrees: -correctionDegrees,
            exitHeadingDegrees: -correctionDegrees,
            commitRootYawOnCompletion: false
        )
    }

    private func consumeFollowLocomotionDelta(
        _ delta: JockRuntimeLocomotionDelta
    ) -> Bool {
        guard !isActionLocked else {
            return true
        }

        guard followDemoState == .following else {
            return true
        }

        guard let headPosition = latestHeadPosition else {
            return true
        }

        let distance = horizontalDistanceToUser(
            headPosition: headPosition
        )

        let remainingSafeTravel =
            distance - followConfiguration.stopDistanceMeters

        guard remainingSafeTravel > 0 else {
            followDemoState = .idleStopped
            followDelayElapsed = 0
            playFollowIdle()
            return true
        }

        let signedAuthoredForward =
            delta.forwardMeters * followConfiguration.followForwardSign

        let authoredForward = max(signedAuthoredForward, 0)

        let scaledForward =
            authoredForward * followConfiguration.walkDistanceScale

        let clampedStep = min(
            scaledForward,
            followConfiguration.maxStepMetersPerFrame,
            remainingSafeTravel
        )

        print(
            """
            [Gravitas Follow] locomotion
              rawForward: \(delta.forwardMeters)
              signedForward: \(signedAuthoredForward)
              distance: \(distance)
              step: \(clampedStep)
            """
        )

        guard clampedStep > 0.00001 else {
            return true
        }

        let rootForward = rootEntity.orientation.act(
            SIMD3<Float>(0, 0, -1)
        )

        let horizontalForward = PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(rootForward.x, 0, rootForward.z),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        rootEntity.position += horizontalForward * clampedStep

        if clampedStep >= remainingSafeTravel - 0.001 {
            followDemoState = .idleStopped
            followDelayElapsed = 0
            playFollowIdle()
        }

        return true
    }

    private func resetRootToDefaultSpawn() {
        resetRootToSpawn(
            visualOffset: cameraFacingVisualOffset
        )
    }

    private func resetRootToLoopSpawn() {
        resetRootToSpawn(
            visualOffset: loopStartVisualOffset
        )
    }

    private func resetRootToSpawn(
        visualOffset: simd_quatf
    ) {
        rootEntity.position = spawnPosition
        rootEntity.orientation = spawnOrientation
        visualOffsetEntity.position = .zero
        visualOffsetEntity.orientation = visualOffset
    }

    private func firstSkinnedModelEntity(in entity: Entity) -> ModelEntity? {
        if let modelEntity = entity as? ModelEntity,
           !modelEntity.jointNames.isEmpty {
            return modelEntity
        }

        for child in entity.children {
            if let found = firstSkinnedModelEntity(in: child) {
                return found
            }
        }

        return nil
    }
}
