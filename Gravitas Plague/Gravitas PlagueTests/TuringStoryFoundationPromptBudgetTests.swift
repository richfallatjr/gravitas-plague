import XCTest
@testable import Gravitas_Plague

final class TuringStoryFoundationPromptBudgetTests: XCTestCase {
    func testCompactPromptKeepsRequiredResponseReserve() {
        let result = TuringStoryFoundationPromptBudget.evaluate(
            prompt: String(repeating: "a", count: 5_100),
            hotspotCount: 32
        )

        XCTAssertTrue(result.withinBudget)
        XCTAssertGreaterThanOrEqual(result.reservedTokens, 1_200)
        XCTAssertLessThanOrEqual(result.promptUTF8Bytes, 8_500)
    }

    func testOversizedUTF8PromptFailsBeforeFoundation() {
        let result = TuringStoryFoundationPromptBudget.evaluate(
            prompt: String(repeating: "a", count: 8_501),
            hotspotCount: 16
        )

        XCTAssertFalse(result.withinBudget)
    }
}
