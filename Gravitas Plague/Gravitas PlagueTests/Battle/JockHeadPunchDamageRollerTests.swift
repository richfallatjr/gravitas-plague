import XCTest
@testable import Gravitas_Plague

@MainActor
final class JockHeadPunchDamageRollerTests: XCTestCase {
    func testProductionProbabilityIsExactlyOneThird() {
        XCTAssertEqual(
            JockSystemHeadPunchDamageRoller.acceptanceProbability,
            1.0 / 3.0
        )
    }

    func testInjectedFalseRollReturnsOverlayOnly() {
        let roller = SequenceRoller([false])

        XCTAssertEqual(
            JockStoryHeadPunchDecisionEvaluator.resolve(
                temporalGateAccepted: true,
                damageRoller: roller
            ),
            .overlayOnly
        )
        XCTAssertEqual(roller.callCount, 1)
    }

    func testInjectedTrueRollReturnsDamageAndInterrupt() {
        let roller = SequenceRoller([true])

        XCTAssertEqual(
            JockStoryHeadPunchDecisionEvaluator.resolve(
                temporalGateAccepted: true,
                damageRoller: roller
            ),
            .damageAndInterrupt
        )
        XCTAssertEqual(roller.callCount, 1)
    }

    func testTemporalDuplicateConsumesNoRoll() {
        let roller = SequenceRoller([false, true])
        var previousEvaluationAt: TimeInterval?
        func resolve(at now: TimeInterval) -> JockStoryHeadPunchDecision {
            let eligible = JockStoryHeadPunchTemporalGate.isEligible(
                previousEvaluationAt: previousEvaluationAt,
                now: now,
                cooldown: 0.25
            )
            if eligible {
                previousEvaluationAt = now
            }
            return JockStoryHeadPunchDecisionEvaluator.resolve(
                temporalGateAccepted: eligible,
                damageRoller: roller
            )
        }

        XCTAssertEqual(resolve(at: 1.0), .overlayOnly)
        XCTAssertEqual(resolve(at: 1.1), .duplicateFeedbackOnly)
        XCTAssertEqual(roller.callCount, 1)
        XCTAssertEqual(resolve(at: 1.25), .damageAndInterrupt)
        XCTAssertEqual(roller.callCount, 2)
    }

    func testNoPityCounterForcesAcceptanceAfterMisses() {
        let roller = SequenceRoller([false, false, false, false])

        for _ in 0..<4 {
            XCTAssertEqual(
                JockStoryHeadPunchDecisionEvaluator.resolve(
                    temporalGateAccepted: true,
                    damageRoller: roller
                ),
                .overlayOnly
            )
        }
        XCTAssertEqual(roller.callCount, 4)
    }

    func testConsecutiveSuccessesAndFailuresAreAllowed() {
        let roller = SequenceRoller([true, true, false, false])
        let decisions = (0..<4).map { _ in
            JockStoryHeadPunchDecisionEvaluator.resolve(
                temporalGateAccepted: true,
                damageRoller: roller
            )
        }

        XCTAssertEqual(
            decisions,
            [.damageAndInterrupt, .damageAndInterrupt, .overlayOnly, .overlayOnly]
        )
        XCTAssertEqual(roller.callCount, 4)
    }

    func testProbabilityRollerSupportsRobotPolicyWithoutChangingGrandmaDefault() {
        XCTAssertFalse(
            JockProbabilityHeadPunchDamageRoller(
                acceptanceProbability: 0
            ).rollDamageAcceptance()
        )
        XCTAssertTrue(
            JockProbabilityHeadPunchDamageRoller(
                acceptanceProbability: 1
            ).rollDamageAcceptance()
        )
        XCTAssertEqual(
            JockSystemHeadPunchDamageRoller.acceptanceProbability,
            1.0 / 3.0
        )
    }

}

@MainActor
private final class SequenceRoller: JockHeadPunchDamageRolling {
    private var decisions: [Bool]
    private(set) var callCount = 0

    init(_ decisions: [Bool]) {
        self.decisions = decisions
    }

    func rollDamageAcceptance() -> Bool {
        callCount += 1
        precondition(!decisions.isEmpty, "Test roller exhausted.")
        return decisions.removeFirst()
    }
}
