import Foundation

enum JockIncomingPunchPolicy: Equatable, Sendable {
    case legacyHorde
    case storyGrandmaThreeX
}

enum JockStoryHeadPunchDecision: String, Equatable, Sendable {
    case duplicateFeedbackOnly = "duplicate_feedback_only"
    case overlayOnly = "overlay_only"
    case damageAndInterrupt = "damage_and_interrupt"
}

protocol JockHeadPunchDamageRolling: AnyObject {
    func rollDamageAcceptance() -> Bool
}

final class JockSystemHeadPunchDamageRoller: JockHeadPunchDamageRolling {
    static let acceptanceProbability: Double = 1.0 / 3.0

    func rollDamageAcceptance() -> Bool {
        Double.random(in: 0..<1) < Self.acceptanceProbability
    }
}

enum JockStoryHeadPunchTemporalGate {
    static func isEligible(
        previousEvaluationAt: TimeInterval?,
        now: TimeInterval,
        cooldown: TimeInterval
    ) -> Bool {
        guard let previousEvaluationAt else { return true }
        return now - previousEvaluationAt >= cooldown
    }
}

enum JockStoryHeadPunchDecisionEvaluator {
    static func resolve(
        temporalGateAccepted: Bool,
        damageRoller: any JockHeadPunchDamageRolling
    ) -> JockStoryHeadPunchDecision {
        guard temporalGateAccepted else {
            return .duplicateFeedbackOnly
        }

        return damageRoller.rollDamageAcceptance()
            ? .damageAndInterrupt
            : .overlayOnly
    }
}
