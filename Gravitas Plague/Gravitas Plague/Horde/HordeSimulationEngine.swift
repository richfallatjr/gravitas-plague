import Foundation
import simd

struct HordeSimulationCommands: Sendable {
    let frameIndex: Int
    let steering: [EnemySteeringCommand]
    let separation: [EnemySeparationCommand]

    static let empty = HordeSimulationCommands(
        frameIndex: 0,
        steering: [],
        separation: []
    )
}

struct EnemySteeringCommand: Sendable {
    let enemyID: UUID
    let state: HordeCrowdSteeringState
    let locomotionDirectionWorld: SIMD3<Float>
}

struct EnemySeparationCommand: Sendable {
    let enemyID: UUID
    let correctionWorld: SIMD3<Float>
}

actor HordeSimulationEngine {
    private var lastCrowdStateByEnemyID: [UUID: HordeCrowdSteeringState] = [:]

    func reset() {
        lastCrowdStateByEnemyID.removeAll()
    }

    func stepCrowd(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemies: [EnemyBodySnapshot],
        brain: [EnemyBrainSnapshot]
    ) -> HordeSimulationCommands {
        let liveIDs = Set(
            brain
                .filter { !$0.isDead }
                .map(\.id)
        )

        lastCrowdStateByEnemyID = lastCrowdStateByEnemyID.filter {
            liveIDs.contains($0.key)
        }

        let steering = CrowdSteeringEngine.step(
            frame: frame,
            player: player,
            enemies: enemies,
            brain: brain,
            previous: lastCrowdStateByEnemyID
        )

        lastCrowdStateByEnemyID = steering.nextStateByEnemyID

        let separation = BodySeparationSolver.solve(
            enemies: enemies,
            brain: brain
        )

        return HordeSimulationCommands(
            frameIndex: frame.frameIndex,
            steering: steering.commands,
            separation: separation
        )
    }
}

private enum CrowdSteeringEngine {
    struct Result {
        let commands: [EnemySteeringCommand]
        let nextStateByEnemyID: [UUID: HordeCrowdSteeringState]
    }

    static func step(
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        enemies: [EnemyBodySnapshot],
        brain: [EnemyBrainSnapshot],
        previous: [UUID: HordeCrowdSteeringState]
    ) -> Result {
        let bodyByID = Dictionary(
            uniqueKeysWithValues: enemies.map { ($0.id, $0) }
        )
        let brainByID = Dictionary(
            uniqueKeysWithValues: brain.map { ($0.id, $0) }
        )

        var commands: [EnemySteeringCommand] = []
        var nextStateByID: [UUID: HordeCrowdSteeringState] = [:]

        for brainSnapshot in brain {
            guard let body = bodyByID[brainSnapshot.id] else {
                continue
            }

            var state = previous[brainSnapshot.id] ??
                initialState(
                    frame: frame,
                    brain: brainSnapshot
                )

            guard shouldUpdateCrowdSteering(
                brain: brainSnapshot
            ) else {
                nextStateByID[brainSnapshot.id] = state
                continue
            }

            let distanceToUser = crowdDistanceXZ(
                brainSnapshot.position,
                player.position
            )

            if distanceToUser <= brainSnapshot.attackProximityMeters +
                HordeCrowdSteeringSettings.attackRangeBufferMeters {
                state = HordeCrowdSteeringState()
            } else if frame.time >= state.nextSolveTime {
                state.nextSolveTime =
                    frame.time +
                    TimeInterval.random(
                        in: HordeCrowdSteeringSettings.solveIntervalMin...HordeCrowdSteeringSettings.solveIntervalMax
                    )

                state = solve(
                    state: state,
                    frame: frame,
                    player: player,
                    selfBrain: brainSnapshot,
                    selfBody: body,
                    enemies: enemies,
                    brainByID: brainByID
                )
            } else {
                updateReGoal(
                    state: &state,
                    deltaTime: frame.deltaTime
                )
            }

            let locomotion = locomotionDirection(
                enemyPosition: brainSnapshot.position,
                userPosition: player.position,
                steerAngleRadians: state.steerAngleRadians
            )

            nextStateByID[brainSnapshot.id] = state
            commands.append(
                EnemySteeringCommand(
                    enemyID: brainSnapshot.id,
                    state: state,
                    locomotionDirectionWorld: locomotion
                )
            )
        }

        return Result(
            commands: commands,
            nextStateByEnemyID: nextStateByID
        )
    }

    private static func initialState(
        frame: FrameClockSnapshot,
        brain: EnemyBrainSnapshot
    ) -> HordeCrowdSteeringState {
        var state = HordeCrowdSteeringState()
        state.steerAngleRadians = brain.crowdSteerAngleRadians
        state.nextSolveTime = frame.time
        return state
    }

    private static func shouldUpdateCrowdSteering(
        brain: EnemyBrainSnapshot
    ) -> Bool {
        guard !brain.isDead,
              !brain.isAttacking,
              !brain.isHitReacting else {
            return false
        }

        switch brain.state {
        case .dead, .hitReaction, .attacking, .closeRangeReady:
            return false
        case .inactive, .idleStopped, .waitingToFollow, .following:
            return true
        }
    }

    private static func solve(
        state inputState: HordeCrowdSteeringState,
        frame: FrameClockSnapshot,
        player: PlayerPoseSnapshot,
        selfBrain: EnemyBrainSnapshot,
        selfBody: EnemyBodySnapshot,
        enemies: [EnemyBodySnapshot],
        brainByID: [UUID: EnemyBrainSnapshot]
    ) -> HordeCrowdSteeringState {
        var state = inputState

        let directToUser = directDirectionToUser(
            enemyPosition: selfBrain.position,
            userPosition: player.position
        )
        let currentForward = rotateFlat(
            directToUser,
            radians: state.steerAngleRadians
        )
        let distance = crowdDistanceXZ(
            selfBrain.position,
            player.position
        )

        let goalRayLength = max(
            0.05,
            distance -
                selfBrain.attackProximityMeters -
                HordeCrowdSteeringSettings.attackRangeBufferMeters
        )

        let forwardRayLength = min(
            HordeCrowdSteeringSettings.forwardRayLengthMeters,
            goalRayLength
        )

        let bodyHeight = max(
            0.01,
            selfBody.maxY - selfBody.minY
        )

        let rayOrigin =
            selfBrain.position +
            SIMD3<Float>(
                0,
                bodyHeight *
                    HordeCrowdSteeringSettings.rayOriginHeightFraction,
                0
            )

        let goal = validateEnemyBodyRay(
            selfBrain: selfBrain,
            originWorld: rayOrigin,
            directionWorld: directToUser,
            length: goalRayLength,
            playerPosition: player.position,
            enemies: enemies,
            brainByID: brainByID
        )

        let forward = validateEnemyBodyRay(
            selfBrain: selfBrain,
            originWorld: rayOrigin,
            directionWorld: currentForward,
            length: forwardRayLength,
            playerPosition: player.position,
            enemies: enemies,
            brainByID: brainByID
        )

        state.lastGoalBlocked = goal.blocked
        state.lastForwardBlocked = forward.blocked
        state.debugGoalBlockerName = goal.debugBlockerName
        state.debugForwardBlockerName = forward.debugBlockerName

        if !goal.blocked {
            state.mode = .reGoalToUser
            state.lockedRotateSign = 0
            return state
        }

        if !forward.blocked {
            state.mode = .flanking
            return state
        }

        if state.lockedRotateSign == 0 {
            state.lockedRotateSign = Bool.random() ? -1 : 1
        }

        let step =
            HordeCrowdSteeringSettings.rotationStepDegrees *
            .pi / 180.0 *
            state.lockedRotateSign

        state.steerAngleRadians += step
        state.mode = .flanking

        return state
    }

    private static func updateReGoal(
        state: inout HordeCrowdSteeringState,
        deltaTime: Float
    ) {
        guard state.mode == .reGoalToUser else {
            return
        }

        let step =
            HordeCrowdSteeringSettings.reGoalDegreesPerSecond *
            .pi / 180.0 *
            deltaTime

        if abs(state.steerAngleRadians) <= step {
            state.steerAngleRadians = 0
            state.mode = .directToUser
            state.lockedRotateSign = 0
            return
        }

        state.steerAngleRadians -= signFloat(state.steerAngleRadians) * step
    }

    private static func validateEnemyBodyRay(
        selfBrain: EnemyBrainSnapshot,
        originWorld: SIMD3<Float>,
        directionWorld: SIMD3<Float>,
        length: Float,
        playerPosition: SIMD3<Float>,
        enemies: [EnemyBodySnapshot],
        brainByID: [UUID: EnemyBrainSnapshot]
    ) -> HordeCrowdRayValidation {
        let origin = SIMD2<Float>(
            originWorld.x,
            originWorld.z
        )
        let direction = normalizeSimulationAxis2(
            SIMD2<Float>(
                directionWorld.x,
                directionWorld.z
            ),
            fallback: SIMD2<Float>(0, -1)
        )

        var bestDistance = Float.greatestFiniteMagnitude
        var bestName: String?

        for enemy in enemies {
            guard enemy.id != selfBrain.id,
                  enemy.isAlive,
                  let otherBrain = brainByID[enemy.id],
                  shouldYield(
                    selfBrain: selfBrain,
                    otherBrain: otherBrain,
                    playerPosition: playerPosition
                  ) else {
                continue
            }

            guard let distance = HordeCrowdEnemyRayMath.rayVsOBB2D(
                origin: origin,
                direction: direction,
                maxDistance: length,
                center: SIMD2<Float>(
                    enemy.centerWorld.x,
                    enemy.centerWorld.z
                ),
                axisX: enemy.rightXZ,
                axisY: enemy.forwardXZ,
                halfX: enemy.halfWidth,
                halfY: enemy.halfDepth
            ) else {
                continue
            }

            if distance < bestDistance {
                bestDistance = distance
                bestName = "enemy:\(enemy.characterID):\(enemy.id.uuidString)"
            }
        }

        return HordeCrowdRayValidation(
            blocked: bestName != nil,
            debugBlockerName: bestName
        )
    }

    private static func shouldYield(
        selfBrain: EnemyBrainSnapshot,
        otherBrain: EnemyBrainSnapshot,
        playerPosition: SIMD3<Float>
    ) -> Bool {
        guard !otherBrain.isDead else {
            return false
        }

        if selfBrain.isAttacking ||
            selfBrain.isHitReacting ||
            selfBrain.isDead {
            return false
        }

        let myDistance = crowdDistanceXZ(
            selfBrain.position,
            playerPosition
        )

        if myDistance <= selfBrain.attackProximityMeters {
            return false
        }

        if otherBrain.isAttacking {
            return true
        }

        let otherDistance = crowdDistanceXZ(
            otherBrain.position,
            playerPosition
        )

        let delta = myDistance - otherDistance

        if delta > HordeCrowdSteeringSettings.rightOfWayDistanceEpsilon {
            return true
        }

        if abs(delta) <= HordeCrowdSteeringSettings.rightOfWayDistanceEpsilon {
            return selfBrain.spawnIndex > otherBrain.spawnIndex
        }

        return false
    }

    private static func directDirectionToUser(
        enemyPosition: SIMD3<Float>,
        userPosition: SIMD3<Float>
    ) -> SIMD3<Float> {
        flatNormalize(
            userPosition - enemyPosition,
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    private static func locomotionDirection(
        enemyPosition: SIMD3<Float>,
        userPosition: SIMD3<Float>,
        steerAngleRadians: Float
    ) -> SIMD3<Float> {
        rotateFlat(
            directDirectionToUser(
                enemyPosition: enemyPosition,
                userPosition: userPosition
            ),
            radians: steerAngleRadians
        )
    }
}

private enum BodySeparationSolver {
    private enum Settings {
        static let skinMeters: Float = 0.015
        static let maxCorrectionPerEnemyPerFrame: Float = 0.09
        static let solverIterations = 3
        static let tieDistanceEpsilon: Float = 0.05
    }

    private struct MutableBody {
        var snapshot: EnemyBodySnapshot

        var id: UUID { snapshot.id }
        var isAttacking: Bool { snapshot.isAttacking }
        var distanceToUserXZ: Float { snapshot.distanceToUserXZ }
        var spawnIndex: Int { snapshot.spawnIndex }
    }

    static func solve(
        enemies: [EnemyBodySnapshot],
        brain: [EnemyBrainSnapshot]
    ) -> [EnemySeparationCommand] {
        let brainByID = Dictionary(
            uniqueKeysWithValues: brain.map { ($0.id, $0) }
        )

        var working = enemies
            .filter {
                $0.isAlive &&
                    !(brainByID[$0.id]?.isDead ?? false)
            }
            .map {
                MutableBody(snapshot: $0)
            }

        guard working.count >= 2 else {
            return []
        }

        var totalCorrectionsByID: [UUID: SIMD3<Float>] = [:]

        for _ in 0..<Settings.solverIterations {
            var correctionsByID: [UUID: SIMD3<Float>] = [:]

            for i in working.indices {
                for j in working.indices where j > i {
                    guard let mtv = minimumTranslationVector(
                        working[i].snapshot,
                        working[j].snapshot
                    ) else {
                        continue
                    }

                    distributeCorrection(
                        mtv: mtv,
                        a: working[i],
                        b: working[j],
                        correctionsByID: &correctionsByID
                    )
                }
            }

            guard !correctionsByID.isEmpty else {
                continue
            }

            for index in working.indices {
                let id = working[index].id

                guard let rawCorrection = correctionsByID[id] else {
                    continue
                }

                let correction = capLength(
                    rawCorrection,
                    maxLength: Settings.maxCorrectionPerEnemyPerFrame
                )

                guard simd_length(correction) > 0.0001 else {
                    continue
                }

                apply(
                    correction,
                    to: &working[index]
                )

                totalCorrectionsByID[
                    id,
                    default: SIMD3<Float>(repeating: 0)
                ] += correction
            }
        }

        return totalCorrectionsByID.map {
            EnemySeparationCommand(
                enemyID: $0.key,
                correctionWorld: $0.value
            )
        }
    }

    private static func distributeCorrection(
        mtv: HordeEnemyBodySeparationMath.MTV,
        a: MutableBody,
        b: MutableBody,
        correctionsByID: inout [UUID: SIMD3<Float>]
    ) {
        let depth =
            mtv.depth +
            Settings.skinMeters

        let axis = SIMD3<Float>(
            mtv.axisXZ.x,
            0,
            mtv.axisXZ.y
        )

        if a.isAttacking && b.isAttacking {
            correctionsByID[
                a.id,
                default: SIMD3<Float>(repeating: 0)
            ] += axis * (depth * 0.5)
            correctionsByID[
                b.id,
                default: SIMD3<Float>(repeating: 0)
            ] -= axis * (depth * 0.5)
            return
        }

        if a.isAttacking && !b.isAttacking {
            correctionsByID[
                b.id,
                default: SIMD3<Float>(repeating: 0)
            ] -= axis * depth
            return
        }

        if b.isAttacking && !a.isAttacking {
            correctionsByID[
                a.id,
                default: SIMD3<Float>(repeating: 0)
            ] += axis * depth
            return
        }

        let lower = lowerPriorityEnemy(
            a,
            b
        )

        if lower.id == a.id {
            correctionsByID[
                a.id,
                default: SIMD3<Float>(repeating: 0)
            ] += axis * depth
        } else {
            correctionsByID[
                b.id,
                default: SIMD3<Float>(repeating: 0)
            ] -= axis * depth
        }
    }

    private static func lowerPriorityEnemy(
        _ a: MutableBody,
        _ b: MutableBody
    ) -> MutableBody {
        let delta = a.distanceToUserXZ - b.distanceToUserXZ

        if delta > Settings.tieDistanceEpsilon {
            return a
        }

        if delta < -Settings.tieDistanceEpsilon {
            return b
        }

        return a.spawnIndex > b.spawnIndex ? a : b
    }

    private static func minimumTranslationVector(
        _ a: EnemyBodySnapshot,
        _ b: EnemyBodySnapshot
    ) -> HordeEnemyBodySeparationMath.MTV? {
        guard a.minY <= b.maxY && a.maxY >= b.minY else {
            return nil
        }

        let axes = [
            a.rightXZ,
            a.forwardXZ,
            b.rightXZ,
            b.forwardXZ
        ]

        let centerDelta = SIMD2<Float>(
            a.centerWorld.x - b.centerWorld.x,
            a.centerWorld.z - b.centerWorld.z
        )

        var bestAxis = SIMD2<Float>(1, 0)
        var bestOverlap = Float.greatestFiniteMagnitude

        for rawAxis in axes {
            let axis = normalizeSimulationAxis2(
                rawAxis,
                fallback: SIMD2<Float>(1, 0)
            )

            let distance = abs(
                simd_dot(centerDelta, axis)
            )

            let aRadius =
                abs(simd_dot(a.rightXZ, axis)) * a.halfWidth +
                abs(simd_dot(a.forwardXZ, axis)) * a.halfDepth

            let bRadius =
                abs(simd_dot(b.rightXZ, axis)) * b.halfWidth +
                abs(simd_dot(b.forwardXZ, axis)) * b.halfDepth

            let overlap = aRadius + bRadius - distance

            if overlap <= 0 {
                return nil
            }

            if overlap < bestOverlap {
                bestOverlap = overlap

                let directionSign: Float =
                    simd_dot(centerDelta, axis) >= 0 ? 1 : -1

                bestAxis = axis * directionSign
            }
        }

        return HordeEnemyBodySeparationMath.MTV(
            axisXZ: bestAxis,
            depth: bestOverlap
        )
    }

    private static func apply(
        _ correction: SIMD3<Float>,
        to body: inout MutableBody
    ) {
        let snapshot = body.snapshot

        body.snapshot = EnemyBodySnapshot(
            id: snapshot.id,
            characterID: snapshot.characterID,
            spawnIndex: snapshot.spawnIndex,
            isAlive: snapshot.isAlive,
            isAttacking: snapshot.isAttacking,
            position: snapshot.position + correction,
            yawRadians: snapshot.yawRadians,
            centerWorld: snapshot.centerWorld + correction,
            rightXZ: snapshot.rightXZ,
            forwardXZ: snapshot.forwardXZ,
            halfWidth: snapshot.halfWidth,
            halfDepth: snapshot.halfDepth,
            minY: snapshot.minY + correction.y,
            maxY: snapshot.maxY + correction.y,
            distanceToUserXZ: snapshot.distanceToUserXZ
        )
    }

    private static func capLength(
        _ value: SIMD3<Float>,
        maxLength: Float
    ) -> SIMD3<Float> {
        let length = simd_length(value)

        guard length > maxLength,
              length > 0.00001 else {
            return value
        }

        return value / length * maxLength
    }
}

private func normalizeSimulationAxis2(
    _ value: SIMD2<Float>,
    fallback: SIMD2<Float>
) -> SIMD2<Float> {
    let length = simd_length(value)

    guard length > 0.00001 else {
        return fallback
    }

    return value / length
}
