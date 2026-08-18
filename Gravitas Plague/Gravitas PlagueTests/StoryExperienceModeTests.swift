import XCTest
@testable import Gravitas_Plague

@MainActor
final class StoryExperienceModeTests: XCTestCase {
    func testProductionModeContractDefaultsToPlay() {
        XCTAssertEqual(
            StoryExperienceModeController.shared.modeForNewStoryAction(),
            .play
        )
    }

    func testExperienceModeIsNotCodable() {
        XCTAssertFalse(StoryExperienceMode.self is any Codable.Type)
    }

    func testPlayAutoplayDoesNotSpoofUserPlayProvenance() {
        let trigger = TuringFlowTriggerSource.playModeAutoplay(
            parentBoundaryID: "test"
        )

        XCTAssertEqual(trigger.kind, .playModeAutoplay)
        XCTAssertEqual(trigger.interactionStartMode, .automatic)
        XCTAssertNotEqual(trigger.kind, .userPlay)
    }

    func testStoryAndHordeCrossSwitchesRequireRuntimeTeardown() {
        XCTAssertTrue(
            PlagueDemoSession.PlagueOperationMode.requiresRuntimeTeardown(
                from: .story,
                to: .horde
            )
        )
        XCTAssertTrue(
            PlagueDemoSession.PlagueOperationMode.requiresRuntimeTeardown(
                from: .horde,
                to: .story
            )
        )
    }

    func testSameModeAndWalkLoopSelectionsDoNotUseStoryHordeTeardown() {
        XCTAssertFalse(
            PlagueDemoSession.PlagueOperationMode.requiresRuntimeTeardown(
                from: .story,
                to: .story
            )
        )
        XCTAssertFalse(
            PlagueDemoSession.PlagueOperationMode.requiresRuntimeTeardown(
                from: .horde,
                to: .horde
            )
        )
        XCTAssertFalse(
            PlagueDemoSession.PlagueOperationMode.requiresRuntimeTeardown(
                from: .walkLoop,
                to: .story
            )
        )
        XCTAssertFalse(
            PlagueDemoSession.PlagueOperationMode.requiresRuntimeTeardown(
                from: nil,
                to: .horde
            )
        )
    }
}
