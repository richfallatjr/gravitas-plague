import XCTest
@testable import Gravitas_Plague

@MainActor
final class StoryExperienceModeTests: XCTestCase {
    func testModeContractDefaultsToPlayAndUsesInverseToggleSymbols() {
        XCTAssertEqual(
            StoryExperienceModeController.shared.modeForNewStoryAction(),
            .play
        )
        XCTAssertEqual(StoryExperienceMode.play.posterToggleSymbolName, "sparkles")
        XCTAssertEqual(StoryExperienceMode.interactive.posterToggleSymbolName, "play.fill")
        XCTAssertEqual(StoryExperienceMode.play.toggleDestination, .interactive)
        XCTAssertEqual(StoryExperienceMode.interactive.toggleDestination, .play)
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
}
