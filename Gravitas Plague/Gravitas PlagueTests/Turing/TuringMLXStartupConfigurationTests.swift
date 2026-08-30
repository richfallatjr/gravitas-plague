import TuringQwenNative
import XCTest

@testable import Gravitas_Plague

final class TuringMLXStartupConfigurationTests: XCTestCase {
    func testProductionDefaultDoesNotAcceptArbitraryRuntimeTuning() throws {
        let configuration = try TuringMLXCommandBufferExperimentConfiguration.current(
            arguments: [
                "--turing-mlx-buffer-profile=operations16Megabytes16",
                "--turing-mlx-targeted-boundary=dynamicRowCheckpoint",
            ]
        )
        #if GR_TURING_QUALIFICATION
        XCTAssertEqual(configuration.profile, .operations16Megabytes16)
        XCTAssertEqual(configuration.targetedBoundary, .dynamicRowCheckpoint)
        #elseif GR_TURING_MLX_PROFILE_OPS16_MB16
        XCTAssertEqual(configuration.profile, .operations16Megabytes16)
        XCTAssertEqual(configuration.targetedBoundary, .none)
        #else
        XCTAssertEqual(configuration.profile, .deviceDefault)
        XCTAssertEqual(configuration.targetedBoundary, .none)
        #endif
    }

    #if GR_TURING_QUALIFICATION
    func testQualificationRejectsDuplicateOrUnknownProfiles() {
        XCTAssertThrowsError(
            try TuringMLXCommandBufferExperimentConfiguration.current(
                arguments: [
                    "--turing-mlx-buffer-profile=deviceDefault",
                    "--turing-mlx-buffer-profile=operations24Megabytes24",
                ]
            )
        )
        XCTAssertThrowsError(
            try TuringMLXCommandBufferExperimentConfiguration.current(
                arguments: ["--turing-mlx-buffer-profile=unknown"]
            )
        )
    }
    #endif
}
