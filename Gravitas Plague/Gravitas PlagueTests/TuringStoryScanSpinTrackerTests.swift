import XCTest
import simd
@testable import Gravitas_Plague

final class TuringStoryScanSpinTrackerTests: XCTestCase {
    @MainActor
    func testSpinDirectionSurvivesYawWrap() throws {
        let tracker = TuringStoryScanSpinTracker()
        tracker.begin(headForward: forward(yaw: .pi - 0.1))
        tracker.update(headForward: forward(yaw: -.pi + 0.1))
        let result = try tracker.finish()

        XCTAssertEqual(result.direction, .counterClockwise)
        XCTAssertEqual(result.accumulatedYawRadians, 0.2, accuracy: 0.01)
    }

    private func forward(yaw: Float) -> SIMD3<Float> {
        SIMD3<Float>(sin(yaw), 0, cos(yaw))
    }
}
