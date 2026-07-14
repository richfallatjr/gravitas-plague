import XCTest
@testable import Gravitas_Plague

@MainActor
final class Battle01GrandmaHordeRegressionTests: XCTestCase {
    func testDefaultIncomingPunchPolicyIsLegacyHorde() {
        XCTAssertEqual(
            JockRetargetTestController().incomingPunchPolicyForDiagnostics,
            .legacyHorde
        )
    }

    func testHordePreparationRestoresLegacyPolicy() throws {
        let controller = JockRetargetTestController()
        controller.configureIncomingPunchPolicy(
            .storyGrandmaThreeX,
            storyBattleInstanceID: UUID(),
            damageRoller: AlwaysAcceptStoryRoller()
        )

        try controller.prepareFreshHordeSpawn(
            enemyID: UUID(),
            spawnIndex: 0,
            hitsToKill: 4
        )

        XCTAssertEqual(controller.incomingPunchPolicyForDiagnostics, .legacyHorde)
    }
}

@MainActor
private final class AlwaysAcceptStoryRoller: JockHeadPunchDamageRolling {
    func rollDamageAcceptance() -> Bool { true }
}
