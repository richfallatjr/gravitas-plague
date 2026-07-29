import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringRollingBenchPlacementContractTests: XCTestCase {
    func testRollingBenchIsSecondPriorityFloorBackedProp() throws {
        let posterSize = SIMD2<Float>(
            WallPosterMetrics.maxHeightMeters * WallPosterMetrics.aspect,
            WallPosterMetrics.maxHeightMeters
        )
        let envelopes = TuringStoryPlanningEnvelope.all(
            posterSize: posterSize
        )
        let bench = try XCTUnwrap(
            envelopes.first { $0.propID == .rollingBench }
        )

        XCTAssertEqual(
            TuringStoryPropID.allCases.sorted { $0.priority < $1.priority },
            [.door, .rollingBench, .window, .walkieShelf, .poster]
        )
        XCTAssertEqual(bench.bottomAboveFloorMeters, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            bench.topAboveFloorMeters,
            TuringRollingBenchTuning.expectedHeightMeters,
            accuracy: 0.000_001
        )
        XCTAssertEqual(TuringStoryWallSliceOption.benchOne.rawValue, "B1")
        XCTAssertEqual(TuringRollingBenchTuning.runtimeScale, 3.0)
    }

    func testRadioContractUsesTransientTuningAndSpatialEmitter() {
        XCTAssertEqual(
            TuringRollingBenchTuning.tuningLoopGainDB,
            20.0 * log10(0.20),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TuringRollingBenchEntityName.runtimeAudioEmitter,
            "TuringRollingBenchCrankRadio_AudioEmitter"
        )
        XCTAssertEqual(
            TuringRollingBenchEntityName.runtimeStaticLane,
            "TuringRollingBenchCrankRadio_StaticLane"
        )
        XCTAssertEqual(
            TuringRollingBenchEntityName.runtimeCueLane,
            "TuringRollingBenchCrankRadio_CueLane"
        )
        XCTAssertEqual(
            TuringRollingBenchEntityName.runtimeBroadcastLane,
            "TuringRollingBenchCrankRadio_BroadcastLane"
        )
    }
}
