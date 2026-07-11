import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringStoryWallSlicePromptTests: XCTestCase {
  func testRepairDelegatesToExactCurrentPrimaryPrompt() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let project = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let promptsURL =
      project
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
    XCTAssertTrue(planner.contains("\"wall\":WALL_NUMBER"))
    XCTAssertTrue(planner.contains("\"score\":NORMALIZED_WALL_AREA"))
    XCTAssertTrue(planner.contains("First prefer a different wall"))
    XCTAssertTrue(planner.contains("largest score"))
    XCTAssertTrue(planner.contains("largest wall surface area"))
    XCTAssertTrue(planner.contains("Every returned slice ID must appear verbatim"))
    XCTAssertTrue(planner.contains("{{availableSliceIDs}}"))
    XCTAssertTrue(planner.contains("do not continue the numeric pattern"))
    XCTAssertFalse(
      planner.contains(
        "exactly these keys and return the same SLICE_ID for different object"
      )
    )
    XCTAssertTrue(planner.contains("exactly the keys d, w, s, p"))
    XCTAssertTrue(repair.contains("{{primaryPrompt}}"))
    XCTAssertTrue(repair.contains("{{previousResponseJSON}}"))
    XCTAssertTrue(repair.contains("{{repairIssuesJSON}}"))
    XCTAssertFalse(repair.contains("door returns one slice advertising D2"))
    XCTAssertFalse(repair.contains("shelf uses one S1 slice"))
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
