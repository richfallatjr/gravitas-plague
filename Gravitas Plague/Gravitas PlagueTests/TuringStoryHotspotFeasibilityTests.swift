import XCTest
@testable import Gravitas_Plague

final class TuringStoryHotspotFeasibilityTests: XCTestCase {
    func testLexicographicSearchKeepsHigherPriorityProps() {
        let wall0 = UUID()
        let wall1 = UUID()
        let placements = [
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "door", propID: .door, wallID: "w0", wallUUID: wall0, localX: 0
            ),
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "window-overlap", propID: .window, wallID: "w0", wallUUID: wall0, localX: 0
            ),
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "window-free", propID: .window, wallID: "w1", wallUUID: wall1, localX: 0
            ),
            TuringStoryPlacementTestSupport.exactPlacement(
                id: "poster-only", propID: .poster, wallID: "w0", wallUUID: wall0, localX: 0
            )
        ]

        let vector = TuringStoryHotspotFeasibility().maximumLexicographicVector(
            catalog: TuringStoryPlacementTestSupport.catalog(placements)
        )

        XCTAssertEqual(vector.compactArray, [1, 1, 0, 0])
    }
}
