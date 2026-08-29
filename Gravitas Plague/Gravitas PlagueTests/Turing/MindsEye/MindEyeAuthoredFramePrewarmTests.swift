import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFramePrewarmTests: XCTestCase {
    func testPrimaryAndBridgePathsPublishBeforeReconcile() throws {
        let source = try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
            ),
            encoding: .utf8
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "publishAuthoredPreparationHint(item)").count - 1,
            3
        )
        XCTAssertTrue(source.contains("TuringAuthoredPresentationPreparationHub.shared.publish(hint)"))
        XCTAssertTrue(source.contains("Task {"))
    }
}
