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

    enum RetargetError: LocalizedError {
        case missingCharacterAsset
        case noSkinnedModelEntity
        case rigValidationFailed([String])
        case clipNotFound(String)
        case pacingLoopMissingClips([String])

        var errorDescription: String? {
            switch self {
            case .missingCharacterAsset:
                return "Missing dad_biped.usdz."
            case .noSkinnedModelEntity:
                return "dad_biped.usdz loaded, but no ModelEntity with jointNames was found."
            case .rigValidationFailed(let missing):
                return "Rig validation failed. Missing joints: \(missing.joined(separator: ", "))"
            case .clipNotFound(let id):
                return "JockAsset clip not found: \(id)"
            case .pacingLoopMissingClips(let ids):
                return "Pacing loop is missing clips: \(ids.joined(separator: ", "))"
            }
        }
    }

    let rootEntity = Entity()

    var onPunchHit: (() -> Void)?

    private let visualOffsetEntity = Entity()

    private var characterEntity: Entity?
    private var modelEntity: ModelEntity?

    private var rigDefinition: JockRigDefinition?
    private var skeletonMap: JockSkeletonMap?
    private var manifest: JockAnimationManifest?
    private var adapter: JockSkeletonAdapter?
    private var driver: JockRuntimeDriver?

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
        case hitReaction(clipID: String, damage: JockHitDamageLevel)
        case dead
    }

    private var combatState: FollowCombatState = .normal
    private var acceptedHitCount: Int = 0
    private var lastHitClipIDBySide: [JockHitSide: String] = [:]
    private var lastHitClipIDByBucket: [String: String] = [:]

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
            return "Hits: \(acceptedHitCount)/\(hitConfiguration.deathHitCount)"

        case .hitReaction(let clipID, let damage):
            return "Hit reaction: \(clipID) \(damage.rawValue) | Hits: \(acceptedHitCount)/\(hitConfiguration.deathHitCount)"

        case .dead:
            return "Dead | Hits: \(acceptedHitCount)/\(hitConfiguration.deathHitCount)"
        }
    }

    private var isActionLocked: Bool {
        switch combatState {
        case .normal:
            return false
        case .hitReaction, .dead:
            return true
        }
    }

    private func resetHitSelectionMemory() {
        lastHitClipIDBySide.removeAll()
        lastHitClipIDByBucket.removeAll()
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

        guard let url = Bundle.main.url(
            forResource: "dad_biped",
            withExtension: "usdz"
        ) else {
            throw RetargetError.missingCharacterAsset
        }

        let loadedEntity = try await Entity(contentsOf: url)
        loadedEntity.name = "dad_biped_loaded_character"

        guard let skinnedModel = firstSkinnedModelEntity(in: loadedEntity) else {
            throw RetargetError.noSkinnedModelEntity
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

        let adapter = JockSkeletonAdapter(
            rig: rig,
            skeletonMap: map,
            runtimeJointNames: skinnedModel.jointNames
        )

        if !adapter.validationReport.missingCanonicalJoints.isEmpty {
            throw RetargetError.rigValidationFailed(
                adapter.validationReport.missingCanonicalJoints
            )
        }

        let driver = JockRuntimeDriver(
            modelEntity: skinnedModel,
            adapter: adapter,
            locomotionRootEntity: rootEntity,
            visualOffsetEntity: visualOffsetEntity
        )

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
        self.hasLoaded = true

        debugStatus = """
        JockAsset Retarget Test loaded.
        Asset: dad_biped.usdz
        Runtime joints: \(skinnedModel.jointNames.count)
        Matched joints: \(adapter.validationReport.matchedJointCount)
        Library clips: \(loadedClips.count)
        """

        print("[Gravitas] \(debugStatus)")
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
    }

    func show() {
        isVisible = true
        rootEntity.isEnabled = true
    }

    func hide() {
        isVisible = false
        isPlayingPacingLoop = false
        followDemoState = .inactive
        combatState = .normal
        acceptedHitCount = 0
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
        combatState = .normal
        acceptedHitCount = 0
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
        combatState = .normal
        acceptedHitCount = 0
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
        combatState = .normal
        acceptedHitCount = 0
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
        combatState = .normal
        acceptedHitCount = 0
        resetHitSelectionMemory()
        followDelayElapsed = 0
        driver?.locomotionDeltaHandler = nil
        hitDetector.stop()
        resetRootToDefaultSpawn()
        driver?.resetPoseWithTransition(
            visualOffset: cameraFacingVisualOffset
        )
    }

    func playFollowDemo() throws {
        show()

        isPlayingPacingLoop = false
        followDemoState = .idleStopped
        followDelayElapsed = 0
        combatState = .normal
        acceptedHitCount = 0
        resetHitSelectionMemory()

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
        combatState = .normal
        acceptedHitCount = 0
        resetHitSelectionMemory()

        driver?.locomotionDeltaHandler = nil
        driver?.stop()
        hitDetector.stop()

        print("[Gravitas Follow] Follow demo stopped")
    }

    func update(
        deltaTime: Float,
        currentHeadPosition: SIMD3<Float>?
    ) {
        guard isVisible else { return }

        latestHeadPosition = currentHeadPosition
        let dt = TimeInterval(deltaTime)

        if followDemoState != .inactive,
           !isActionLocked,
           currentHeadPosition != nil {
            updateHitDetectionIfNeeded(
                currentTime: Date().timeIntervalSinceReferenceDate
            )
        }

        if !isActionLocked {
            updateFollowDemoIfNeeded(
                deltaTime: dt,
                currentHeadPosition: currentHeadPosition
            )
        }

        driver?.update(deltaTime: dt)
    }

    private func handleJockClipCompleted(_ completedClip: JockAnimClip) {
        switch combatState {
        case .hitReaction(let clipID, let damage):
            guard completedClip.clipID == clipID else {
                return
            }

            print(
                """
                [Gravitas Hit] Hit reaction completed
                  clipID: \(clipID)
                  damage: \(damage.rawValue)
                """
            )

            combatState = .normal

            if followDemoState != .inactive {
                driver?.locomotionDeltaHandler = { [weak self] delta in
                    self?.consumeFollowLocomotionDelta(delta) ?? true
                }

                followDemoState = .idleStopped
                followDelayElapsed = 0
                playFollowIdle()
            }

        case .dead:
            return

        case .normal:
            handleClipCompleted(completedClip)
        }
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
        let faceCenter = estimatedCharacterFaceCenterWorldPosition()

        guard let event = hitDetector.update(
            currentTime: currentTime,
            characterRoot: rootEntity,
            faceCenterWorld: faceCenter
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

    private func handleHitEvent(
        _ event: JockHandHitDetector.HitEvent
    ) {
        guard followDemoState != .inactive else { return }
        guard !isActionLocked else { return }

        acceptedHitCount += 1
        onPunchHit?()

        let shouldDie = acceptedHitCount >= hitConfiguration.deathHitCount
        let finalDamage: JockHitDamageLevel = shouldDie
            ? .death
            : event.damageLevel
        let authoredClipSide = authoredHitClipSide(
            forDetectedFaceSide: event.side
        )
        let selectedClipID: String?

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
              deterministicSide: \(event.side.rawValue)
              authoredClipSide: \(authoredClipSide.rawValue)
              classifiedDamage: \(event.damageLevel.rawValue)
              finalDamage: \(finalDamage.rawValue)
              velocity: \(String(format: "%.2f", event.velocityMetersPerSecond)) m/s
              selectedClip: \(selectedClipID ?? "none")
              shouldDie: \(shouldDie)
            """
        )

        applyHitKnockback(
            damage: finalDamage
        )

        guard let selectedClipID,
              let clip = clipsByID[selectedClipID] else {
            print("[Gravitas Hit] No valid hit clip found. Falling back to idle.")
            combatState = .normal
            playFollowIdle()
            return
        }

        if shouldDie {
            combatState = .dead
            followDemoState = .inactive
            hitDetector.stop()

            driver?.playClip(
                clip,
                loop: false,
                transition: true,
                runtimeOverride: followVisualRuntimeOverride()
            )

            print("[Gravitas Hit] Death triggered. Follow disabled.")
        } else {
            combatState = .hitReaction(
                clipID: selectedClipID,
                damage: finalDamage
            )

            driver?.playClip(
                clip,
                loop: false,
                transition: true,
                runtimeOverride: followVisualRuntimeOverride()
            )
        }
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

    private func playFollowIdle() {
        guard !isActionLocked else {
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
