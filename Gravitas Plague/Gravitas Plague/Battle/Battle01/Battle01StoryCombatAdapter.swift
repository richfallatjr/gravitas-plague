import Foundation

@MainActor
final class Battle01StoryCombatAdapter: Battle01StoryCombatControlling {
    private weak var enemy: JockRetargetTestController?
    private var context: StoryEnemyCombatContext?
    private var active = false

    func activate(
        enemy: JockRetargetTestController,
        context: StoryEnemyCombatContext
    ) throws {
        self.enemy = enemy
        self.context = context
        self.active = true

        enemy.onBenchmarkPlayerHit = { _, _ in false }
        enemy.onPlayerDamaged = { [weak self] amount in
            guard let self else { return }
            self.context?.onPlayerDamage(Float(amount))
        }
        enemy.onBenchmarkEnemyKilled = { [weak self] _, _ in
            self?.context?.onEnemyDeathStarted()
        }
        enemy.onBenchmarkEnemyDeathAnimationFinished = { [weak self] _, _ in
            guard let self else { return }
            self.active = false
            self.context?.onEnemyDeathAnimationCompleted()
        }
        enemy.setIncomingPunchPolicy(
            .storyGrandmaRandomDamageReaction(probability: 0.33)
        )
        try enemy.activateStoryCombat()

        print("""
        [Battle01] combat activated
          battleInstanceID: \(context.battleInstanceID.uuidString)
          enemyID: \(enemy.hordeBenchmarkID.uuidString)
          hordeWaveOwner: false
          randomHeadPunchDamageReactionProbability: 0.33
          headSnapAlwaysLayered: true
        """)
    }

    func update(deltaTime: TimeInterval) {
        guard active,
              let enemy,
              let target = context?.playerTargetProvider() else { return }
        enemy.update(
            deltaTime: Float(deltaTime),
            currentHeadPosition: target
        )
    }

    func disableCombat(reason: String) {
        guard active else { return }
        active = false
        enemy?.setCombatEnabled(false)
        print("[Battle01] combat disabled reason=\(reason)")
    }

    func cancel(reason: String) {
        disableCombat(reason: reason)
        enemy = nil
        context = nil
    }
}
