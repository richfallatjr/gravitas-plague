import Foundation
import RealityKit
import simd

protocol BattleClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ProductionBattleClock: BattleClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
protocol ScriptedEnemyAnimating: AnyObject {
    func playScriptedIdleLoop() throws
    func playScriptedRightTurn90(
        token: UUID,
        completion: @escaping @MainActor (UUID, Result<Void, Error>) -> Void
    ) throws
    func playScriptedWalkLoop(
        onAuthoredTravel: @escaping @MainActor (Float) -> Void
    ) throws
    func stopScriptedLocomotion(reason: String)
    func steerScriptedRootTowardWorldDirection(
        _ direction: SIMD3<Float>,
        deltaTime: Float
    )
    func setExternalMotionDriven(_ enabled: Bool)
    func setRootMotionEnabled(_ enabled: Bool)
}

struct StoryEnemyCombatContext {
    let battleInstanceID: UUID
    let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    let onPlayerDamage: @MainActor (Float) -> Void
    let onEnemyDeathStarted: @MainActor () -> Void
    let onEnemyDeathAnimationCompleted: @MainActor () -> Void
}

@MainActor
protocol Battle01StoryCombatControlling: AnyObject {
    func activate(
        enemy: JockRetargetTestController,
        context: StoryEnemyCombatContext
    ) throws
    func update(deltaTime: TimeInterval)
    func disableCombat(reason: String)
    func cancel(reason: String)
}

@MainActor
protocol Battle01SoundtrackControlling: AnyObject {
    func prepare(fileURL: URL) throws
    func prepareAftermathLoop(fileURL: URL) throws
    func playOnce(
        battleInstanceID: UUID,
        onStarted: @escaping @MainActor (UUID) -> Void,
        onCompleted: @escaping @MainActor (UUID, Bool) -> Void
    ) throws
    func crossfadeToAftermathLoop(
        battleInstanceID: UUID,
        targetDecibels: Float,
        fadeDurationSeconds: TimeInterval,
        onStarted: @escaping @MainActor (UUID) -> Void
    ) throws
    func stop(reason: String)
}

@MainActor
protocol Battle01RichPrerecordingPlaying: AnyObject {
    func play(
        descriptor: TuringPrerecordingDescriptor,
        fileURL: URL,
        battleInstanceID: UUID
    ) async throws
    func cancel(reason: String)
}

extension JockRetargetTestController: ScriptedEnemyAnimating {}
