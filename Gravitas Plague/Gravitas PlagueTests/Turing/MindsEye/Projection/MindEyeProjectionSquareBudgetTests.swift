import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionSquareBudgetTests: XCTestCase {
    func testSquareProfilesPreserveExistingPixelAndByteBudgets() {
        XCTAssertEqual(2_304 * 1_296, 1_728 * 1_728)
        XCTAssertEqual(1_920 * 1_080, 1_440 * 1_440)
        XCTAssertEqual(2_304 * 1_296 * 4, 1_728 * 1_728 * 4)
        XCTAssertEqual(1_920 * 1_080 * 4, 1_440 * 1_440 * 4)
        XCTAssertFalse(MindEyeCompositorCanvasProfile.squareFacialProjection.permitsInternalMotion)
        XCTAssertTrue(MindEyeCompositorCanvasProfile.landscapePortraitCard.permitsInternalMotion)
    }
}
