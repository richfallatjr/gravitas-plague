import Foundation
import simd

struct Chapter01DadBattlePlayerDamagePolicy: Sendable, Equatable {
    let damageEnableMediaTime: TimeInterval

    func disposition(
        soundtrackMediaTime: TimeInterval?
    ) -> StoryPlayerContactDisposition {
        guard let soundtrackMediaTime,
              soundtrackMediaTime >= damageEnableMediaTime else {
            return .feedbackOnly
        }
        return .applyDamage
    }
}

struct Chapter01DadBattleCombatContext {
    let battleInstanceID: UUID
    let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    let onPlayerContactFeedback: @MainActor () -> Void
    let onPlayerDamage: @MainActor (Int) -> Void
    let onPlayerDeath: @MainActor () -> Void
    let onOneAcceptedDamageRemaining: @MainActor () -> Void
    let onEnemyDeathStarted: @MainActor () -> Void
    let onEnemyDeathAnimationCompleted: @MainActor () -> Void
}

@MainActor
final class Chapter01DadBattleCombatAdapter {
    private weak var enemy: JockRetargetTestController?
    private let damageClock: Chapter01DadBattleDamageClock
    private let damagePolicy: Chapter01DadBattlePlayerDamagePolicy
    private let hitBudget: StoryPlayerHitBudget
    private var context: Chapter01DadBattleCombatContext?
    private var active = false
    private var oneRemainingCueClaimed = false
    private var playerDeathClaimed = false

    init(
        damageClock: Chapter01DadBattleDamageClock,
        damageEnableMediaTime: TimeInterval,
        confirmedHitsToKill: Int
    ) {
        self.damageClock = damageClock
        self.damagePolicy = Chapter01DadBattlePlayerDamagePolicy(
            damageEnableMediaTime: damageEnableMediaTime
        )
        self.hitBudget = StoryPlayerHitBudget(
            maximumConfirmedHits: confirmedHitsToKill
        )
    }

    var damageIsEnabled: Bool {
        guard let mediaTime = damageClock.currentMediaTime else { return false }
        return damagePolicy.disposition(soundtrackMediaTime: mediaTime) ==
            .applyDamage
    }

    func activate(
        enemy: JockRetargetTestController,
        context: Chapter01DadBattleCombatContext
    ) throws {
        self.enemy = enemy
        self.context = context
        active = true

        enemy.onStoryPlayerAttackContact = { [weak self] contact in
            guard let self, self.active else { return .feedbackOnly }
            self.context?.onPlayerContactFeedback()
            let mediaTime = self.damageClock.currentMediaTime
            let disposition = self.damagePolicy.disposition(
                soundtrackMediaTime: mediaTime
            )
            print(
                "[Chapter01DadBattle] player contact " +
                    "mediaTime=\(mediaTime.map { String(format: "%.3f", $0) } ?? "none") " +
                    "clipID=\(contact.attackClipID ?? "none") " +
                    "disposition=\(String(describing: disposition))"
            )
            return disposition
        }
        enemy.onBenchmarkPlayerHit = { [weak self] amount, _ in
            guard let self, self.active, self.damageIsEnabled else { return false }
            let terminal = self.hitBudget.registerConfirmedHit()
            let snapshot = self.hitBudget.snapshot()
            print(
                "[Chapter01DadBattle] confirmed player hit " +
                    "count=\(snapshot.confirmedHits)/\(snapshot.maximum) terminal=\(terminal)"
            )
            if terminal, !self.playerDeathClaimed {
                self.playerDeathClaimed = true
                self.context?.onPlayerDamage(amount)
                self.context?.onPlayerDeath()
            }
            return terminal
        }
        enemy.setStoryPlayerHitCallbackOwnsBudget(true)
        enemy.onPlayerDamaged = { [weak self] amount in
            guard let self, self.active else { return }
            self.context?.onPlayerDamage(amount)
        }
        enemy.onStoryAcceptedDamageChanged = { [weak self] snapshot in
            guard let self else { return }
            print(
                "[Chapter01DadBattle] accepted Dad damage " +
                    "count=\(snapshot.acceptedHitCount) " +
                    "capacity=\(snapshot.acceptedHitCapacity) " +
                    "remaining=\(snapshot.remainingAcceptedDamagePoints) " +
                    "lethal=\(snapshot.isLethal)"
            )
            guard snapshot.remainingAcceptedDamagePoints == 1,
                  !snapshot.isLethal,
                  !self.oneRemainingCueClaimed else { return }
            self.oneRemainingCueClaimed = true
            self.context?.onOneAcceptedDamageRemaining()
        }
        enemy.onBenchmarkEnemyKilled = { [weak self] _, _ in
            self?.context?.onEnemyDeathStarted()
        }
        enemy.onBenchmarkEnemyDeathAnimationFinished = { [weak self] _, _ in
            guard let self else { return }
            self.active = false
            self.context?.onEnemyDeathAnimationCompleted()
        }
        try enemy.activateStoryCombat()
        print(
            "[Chapter01DadBattle] combat activated " +
                "battleInstanceID=\(context.battleInstanceID.uuidString) " +
                "damageEnableMediaTime=\(damagePolicy.damageEnableMediaTime) " +
                "confirmedHitsToKill=\(hitBudget.snapshot().maximum)"
        )
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

    func disable(reason: String) {
        guard active else { return }
        active = false
        hitBudget.disable()
        enemy?.setCombatEnabled(false)
        print("[Chapter01DadBattle] combat disabled reason=\(reason)")
    }

    func cancelAndRelease(reason: String) {
        disable(reason: reason)
        enemy?.onStoryPlayerAttackContact = nil
        enemy?.onStoryAcceptedDamageChanged = nil
        enemy = nil
        context = nil
    }
}
