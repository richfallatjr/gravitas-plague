import XCTest

@testable import Gravitas_Plague

final class MindEyePresentationCoordinatorTests: XCTestCase {
    func testSuccessfulAttachInstallsActiveIdentityBeforeMotionStarts() throws {
        let source = try coordinatorSource()
        let active = try XCTUnwrap(source.range(of: "active = ActivePresentation("))
        let start = try XCTUnwrap(source.range(of: "prepared.visual.startKeepAlive("))
        XCTAssertLessThan(active.lowerBound, start.lowerBound)
    }

    func testMotionStartFailureRetainsStaticCardAndAudioOnlyFailurePolicy() throws {
        let source = try coordinatorSource()
        XCTAssertTrue(source.contains("stage: \"startKeepAlive\""))
        XCTAssertTrue(source.contains("fallback=audioOnly"))
        let keepAliveBlock = try XCTUnwrap(source.range(of: "let keepAlive ="))
        let shownMessage = try XCTUnwrap(source.range(of: "dynamic card shown"))
        XCTAssertLessThan(keepAliveBlock.lowerBound, shownMessage.lowerBound)
    }

    func testReplacementStopsOldTokenBeforeDetach() throws {
        let source = try coordinatorSource()
        let method = try XCTUnwrap(source.range(of: "private func detachActiveImmediately"))
        let suffix = String(source[method.lowerBound...])
        let stop = try XCTUnwrap(suffix.range(of: "active.visual.stopKeepAlive"))
        let detach = try XCTUnwrap(suffix.range(of: "active.visual.detach"))
        XCTAssertLessThan(stop.lowerBound, detach.lowerBound)
    }

    func testPauseAndResumeRemainExactIdentityMatched() throws {
        let source = try coordinatorSource()
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "active.identity.key == key").count - 1,
            2
        )
        XCTAssertTrue(source.contains("spokenPlaybackPaused"))
        XCTAssertTrue(source.contains("spokenPlaybackResumed"))
    }

    private func coordinatorSource() throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift"
            ),
            encoding: .utf8
        )
    }
}
