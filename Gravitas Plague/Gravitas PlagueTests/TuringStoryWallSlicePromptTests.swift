import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringStoryWallSlicePromptTests: XCTestCase {
  func testPrimaryPromptContainsReadablePlacementContract() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let project = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let promptsURL =
      project
      .appendingPathComponent("TuringResources/Turing/Prompts")
    let planner = try String(
      contentsOf: promptsURL.appendingPathComponent("storyWallSliceLayoutPlanner.txt"),
      encoding: .utf8
    )
    XCTAssertTrue(planner.contains("Slices are already listed in room order"))
    XCTAssertTrue(planner.contains("\"wall\":WALL_NUMBER"))
    XCTAssertTrue(planner.contains("\"score\":NORMALIZED_WALL_AREA"))
    XCTAssertTrue(planner.contains("First prefer a different wall"))
    XCTAssertTrue(planner.contains("largest score"))
    XCTAssertTrue(planner.contains("largest wall surface area"))
    XCTAssertTrue(planner.contains("Every returned slice ID must appear verbatim"))
    XCTAssertTrue(planner.contains("exactly the keys d, w, s, p"))
    XCTAssertFalse(planner.contains("v must be"))
    XCTAssertFalse(planner.contains("scan must"))

    for poisonedExample in ["[\"11\",\"12\"]", "[\"21\"]", "[\"31\"]", "[\"42\"]"] {
      XCTAssertFalse(planner.contains(poisonedExample))
    }
  }

  func testWallSlicePlannerHasOneFoundationRequestAndNoRepairRequest() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let project = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = project.appendingPathComponent(
      "Gravitas Plague/Turing/Placement/TuringStoryWallSliceLayoutPlanner.swift"
    )
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertEqual(source.components(separatedBy: "runner.runPrompt(").count - 1, 1)
    XCTAssertFalse(source.contains("storyWallSliceLayoutRepair"))
    XCTAssertFalse(source.contains("func repair("))
  }
}
