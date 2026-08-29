import XCTest

@testable import Gravitas_Plague

final class MindEyePhase8CoordinatorTests: XCTestCase {
    func testCoordinatorOwnsConcurrentTrackVisualLifecycleAndExactClockForwarding() throws {
        let source = try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("scheduleAuthoredTrackAcquisition("))
        XCTAssertTrue(source.contains("attemptPresentDesiredContext(reason: \"actualSpokenStart\")"))
        XCTAssertTrue(source.contains("preparedAuthoredTrack"))
        XCTAssertTrue(source.contains("lateTrackJoin"))
        XCTAssertTrue(source.contains("updateAuthoredMouthClock("))
        XCTAssertTrue(source.contains("authoredTrackLease"))
        XCTAssertTrue(source.contains("authoredTrackNoLongerDesired"))
    }
}
