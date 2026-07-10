import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringStoryWallSlicePromptTests: XCTestCase {
    func testPromptTeachesWallFirstRankingAndUsesDatasetIDsOnly() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let project = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let promptsURL = project
            .appendingPathComponent("TuringResources/Turing/Prompts")
        let planner = try String(
            contentsOf: promptsURL.appendingPathComponent("storyWallSliceLayoutPlanner.txt"),
            encoding: .utf8
        )
        let repair = try String(
            contentsOf: promptsURL.appendingPathComponent("storyWallSliceLayoutRepair.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(planner.contains("Slices are already listed in room order"))
        XCTAssertTrue(planner.contains("rank currently unused walls"))
        XCTAssertTrue(planner.contains("Every returned slice ID must appear verbatim"))
        XCTAssertTrue(repair.contains("one selected option-start slice ID"))
        XCTAssertTrue(repair.contains("must be non-null in the replacement"))
        XCTAssertTrue(repair.contains("Every returned slice ID must appear verbatim"))
        XCTAssertTrue(repair.contains("Do not reuse any ID identified as unknown"))
        XCTAssertTrue(planner.contains("exactly the keys d, w, s, p"))
        XCTAssertTrue(repair.contains("exactly the keys d, w, s, p"))
        XCTAssertFalse(planner.contains("v must be"))
        XCTAssertFalse(planner.contains("scan must"))
        XCTAssertFalse(repair.contains("v must be"))
        XCTAssertFalse(repair.contains("scan must"))

        for poisonedExample in ["[\"11\",\"12\"]", "[\"21\"]", "[\"31\"]", "[\"42\"]"] {
            XCTAssertFalse(planner.contains(poisonedExample))
            XCTAssertFalse(repair.contains(poisonedExample))
        }
    }
}
