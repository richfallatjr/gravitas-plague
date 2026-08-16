import Foundation
import simd

struct Chapter03BikerCombatContext {
    let battleInstanceID: UUID
    let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    let onPlayerContactFeedback: @MainActor (Int) -> Void
    let onPlayerDeath: @MainActor () -> Void
    let onEnemyDeathStarted: @MainActor () -> Void
    let onEnemyDeathAnimationCompleted: @MainActor () -> Void
}

@MainActor
final class Chapter03BikerBattleCombatAdapter {
    private weak var enemy: JockRetargetTestController?
    private let hitBudget: StoryPlayerHitBudget
    private var context: Chapter03BikerCombatContext?
    private var active = false
    private var playerDeathClaimed = false

    init(confirmedHitsToKill: Int) {
        hitBudget = StoryPlayerHitBudget(maximumConfirmedHits: confirmedHitsToKill)
    }

    func activate(
        enemy: JockRetargetTestController,
        context: Chapter03BikerCombatContext
    ) throws {
        self.enemy = enemy
        self.context = context
        active = true
        enemy.onStoryPlayerAttackContact = { [weak self] contact in
            guard let self, self.active else { return .feedbackOnly }
            self.context?.onPlayerContactFeedback(contact.amount)
            return .applyDamage
        }
        enemy.onBenchmarkPlayerHit = { [weak self] _, _ in
            guard let self, self.active else { return false }
            let terminal = self.hitBudget.registerConfirmedHit()
            if terminal, !self.playerDeathClaimed {
                self.playerDeathClaimed = true
                self.context?.onPlayerDeath()
            }
            return terminal
        }
        enemy.setStoryPlayerHitCallbackOwnsBudget(true)
        enemy.onBenchmarkEnemyKilled = { [weak self] _, _ in
            self?.context?.onEnemyDeathStarted()
        }
        enemy.onBenchmarkEnemyDeathAnimationFinished = { [weak self] _, _ in
            guard let self else { return }
            self.active = false
            self.context?.onEnemyDeathAnimationCompleted()
        }
        try enemy.activateStoryCombat()
    }

    func update(deltaTime: TimeInterval) {
        guard active, let enemy, let target = context?.playerTargetProvider() else { return }
        enemy.update(deltaTime: Float(deltaTime), currentHeadPosition: target)
    }

    func cancelAndRelease(reason: String) {
        active = false
        hitBudget.disable()
        enemy?.setCombatEnabled(false)
        enemy?.onStoryPlayerAttackContact = nil
        enemy?.onBenchmarkPlayerHit = nil
        enemy?.onBenchmarkEnemyKilled = nil
        enemy?.onBenchmarkEnemyDeathAnimationFinished = nil
        enemy = nil
        context = nil
        print("[Chapter03BikerBattle] combat released reason=\(reason)")
    }
}

struct Chapter03MikeCombatContext {
    let battleInstanceID: UUID
    let playerTargetProvider: @MainActor () -> SIMD3<Float>?
    let onPlayerContactFeedback: @MainActor (Int) -> Void
    let onPlayerDeath: @MainActor () -> Void
    let onNonlethalDefeatThreshold: @MainActor (StoryEnemyAcceptedDamageSnapshot) -> Void
}

@MainActor
final class Chapter03MikeBattleCombatAdapter {
    private weak var enemy: JockRetargetTestController?
    private let hitBudget: StoryPlayerHitBudget
    private var context: Chapter03MikeCombatContext?
    private var active = false
    private(set) var postDefeatMode = false
    private var playerDeathClaimed = false
    private var thresholdClaimed = false

    init(confirmedHitsToKill: Int) {
        hitBudget = StoryPlayerHitBudget(maximumConfirmedHits: confirmedHitsToKill)
    }

    func activate(
        enemy: JockRetargetTestController,
        context: Chapter03MikeCombatContext
    ) throws {
        self.enemy = enemy
        self.context = context
        active = true
        enemy.onStoryPlayerAttackContact = { [weak self] contact in
            guard let self, self.active else { return .feedbackOnly }
            self.context?.onPlayerContactFeedback(contact.amount)
            return self.postDefeatMode ? .feedbackOnly : .applyDamage
        }
        enemy.onStoryEnemyDamageDisposition = { [weak self] in
            guard let self, self.active else { return .headSnapAndImpactOnly }
            return self.postDefeatMode ? .headSnapAndImpactOnly : .applyDamage
        }
        enemy.onBenchmarkPlayerHit = { [weak self] _, _ in
            guard let self, self.active, !self.postDefeatMode else { return false }
            let terminal = self.hitBudget.registerConfirmedHit()
            if terminal, !self.playerDeathClaimed {
                self.playerDeathClaimed = true
                self.context?.onPlayerDeath()
            }
            return terminal
        }
        enemy.setStoryPlayerHitCallbackOwnsBudget(true)
        enemy.onStoryNonlethalDefeatThresholdReached = { [weak self] snapshot in
            guard let self, self.active, !self.thresholdClaimed else { return }
            self.thresholdClaimed = true
            self.postDefeatMode = true
            self.hitBudget.disable()
            self.context?.onNonlethalDefeatThreshold(snapshot)
        }
        enemy.onBenchmarkEnemyKilled = { _, _ in
            assertionFailure("Big Mike entered the lethal death callback.")
        }
        enemy.onBenchmarkEnemyDeathAnimationFinished = { _, _ in
            assertionFailure("Big Mike played a death animation.")
        }
        try enemy.activateStoryCombat()
    }

    func update(deltaTime: TimeInterval) {
        guard active, let enemy, let target = context?.playerTargetProvider() else { return }
        enemy.update(deltaTime: Float(deltaTime), currentHeadPosition: target)
    }

    func stopUnderFullBlack(reason: String) {
        guard active else { return }
        active = false
        hitBudget.disable()
        enemy?.setCombatEnabled(false)
        print("[Chapter03MikeBattle] combat stopped under full black reason=\(reason)")
    }

    func releaseUnderFullBlack(reason: String) {
        stopUnderFullBlack(reason: reason)
        enemy?.onStoryPlayerAttackContact = nil
        enemy?.onStoryEnemyDamageDisposition = nil
        enemy?.onBenchmarkPlayerHit = nil
        enemy?.onStoryNonlethalDefeatThresholdReached = nil
        enemy?.onBenchmarkEnemyKilled = nil
        enemy?.onBenchmarkEnemyDeathAnimationFinished = nil
        enemy = nil
        context = nil
    }
}
