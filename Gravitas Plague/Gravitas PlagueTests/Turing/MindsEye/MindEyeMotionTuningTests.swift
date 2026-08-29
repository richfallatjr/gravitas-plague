import XCTest

@testable import Gravitas_Plague

final class MindEyeMotionTuningTests: XCTestCase {
    func testBigMikePackageResolvesProductionMotionAndBlinkTuning() throws {
        let tuning = try MindEyeKeepAliveTuningResolver.resolve(
            package: makeMindEyeTestPackage()
        ).get()
        XCTAssertGreaterThan(tuning.characterDepthMeters, 0)
        XCTAssertGreaterThan(tuning.backgroundDepthMeters, tuning.characterDepthMeters)
        XCTAssertTrue((0.20...0.35).contains(tuning.backgroundCounterMotion))
        XCTAssertGreaterThanOrEqual(tuning.blink.ordinaryIntervalSeconds.lowerBound, 0.5)
        XCTAssertLessThanOrEqual(tuning.blink.ordinaryIntervalSeconds.upperBound, 5)
        XCTAssertTrue((5...8).contains(tuning.blink.closedReferenceFrames.lowerBound))
        XCTAssertTrue((5...8).contains(tuning.blink.closedReferenceFrames.upperBound))
        XCTAssertGreaterThan(tuning.openEyeVariantCount, 0)
        XCTAssertGreaterThan(tuning.closedEyeVariantCount, 0)
        XCTAssertTrue(tuning.projection.focalPixels.isFinite)
        XCTAssertGreaterThan(tuning.projection.focalPixels, 0)
    }
}
