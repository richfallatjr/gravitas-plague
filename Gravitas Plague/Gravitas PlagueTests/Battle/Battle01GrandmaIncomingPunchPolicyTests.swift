import XCTest
@testable import Gravitas_Plague

@MainActor
final class Battle01GrandmaIncomingPunchPolicyTests: XCTestCase {
    func testExplicitStoryConfigurationInstallsThreeXPolicy() {
        let controller = JockRetargetTestController()

        controller.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: UUID(),
            damageRoller: SequenceStoryRoller(false)
        )

        XCTAssertEqual(
            controller.incomingPunchPolicyForDiagnostics,
            .storyGrandmaThreeX
        )
    }

    func testFreshStoryPreparationRequiresFactoryToReinstallPolicy() {
        let controller = JockRetargetTestController()
        controller.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: UUID(),
            damageRoller: SequenceStoryRoller(true)
        )

        controller.prepareFreshStoryBattleSpawn()

        XCTAssertEqual(controller.incomingPunchPolicyForDiagnostics, .legacyHorde)
    }

    func testExplicitStoryRobotConfigurationDoesNotChangeGrandmaPolicy() {
        let controller = JockRetargetTestController()
        controller.configureIncomingPunchPolicy(
            .storyRobotTenPercent,
            storyBattleInstanceID: UUID(),
            damageRoller: SequenceStoryRoller(false)
        )

        XCTAssertEqual(
            controller.incomingPunchPolicyForDiagnostics,
            .storyRobotTenPercent
        )
    }
}

@MainActor
private final class SequenceStoryRoller: JockHeadPunchDamageRolling {
    private let decision: Bool

    init(_ decision: Bool) {
        self.decision = decision
    }

    func rollDamageAcceptance() -> Bool { decision }
}
