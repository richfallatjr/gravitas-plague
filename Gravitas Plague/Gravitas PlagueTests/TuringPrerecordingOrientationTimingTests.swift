import XCTest
@testable import Gravitas_Plague

final class TuringPrerecordingOrientationTimingTests: XCTestCase {
    func testFixedSamplerAcceptsClosedRangeEndpoints() {
        XCTAssertEqual(
            TuringFixedPrerecordingOrientationDurationSampler(seconds: 2).sampleSeconds(),
            2
        )
        XCTAssertEqual(
            TuringFixedPrerecordingOrientationDurationSampler(seconds: 5).sampleSeconds(),
            5
        )
    }

    func testSystemSamplerStaysInsideClosedRange() {
        for _ in 0..<1_000 {
            XCTAssertTrue(
                (2.0...5.0).contains(
                    TuringSystemPrerecordingOrientationDurationSampler()
                        .sampleSeconds()
                )
            )
        }
    }

    func testOnlyPrimaryAndBridgeRolesAreEligible() throws {
        let descriptor = try TuringFlowDescriptorStore().require(
            "prologue.scriptPoint01"
        )

        XCTAssertTrue(
            TuringPrerecordingOrientationEligibility.permits(
                descriptor: descriptor,
                role: .primaryPrerecording
            )
        )
        XCTAssertTrue(
            TuringPrerecordingOrientationEligibility.permits(
                descriptor: descriptor,
                role: .authoredBridge
            )
        )
        XCTAssertFalse(
            TuringPrerecordingOrientationEligibility.permits(
                descriptor: descriptor,
                role: .openingCue
            )
        )
        XCTAssertFalse(
            TuringPrerecordingOrientationEligibility.permits(
                descriptor: descriptor,
                role: .closingBumper
            )
        )
    }

    func testChapter02WindowAndBattleCinematicsAreExcluded() throws {
        for scriptPointID in [
            "chapter02.room.rich.windowRecognition.001",
            "chapter02.room.rich.womanBattle.001"
        ] {
            let descriptor = try TuringFlowDescriptorStore().require(scriptPointID)
            XCTAssertFalse(
                TuringPrerecordingOrientationEligibility.permits(
                    descriptor: descriptor,
                    role: .primaryPrerecording
                )
            )
        }
    }
}
