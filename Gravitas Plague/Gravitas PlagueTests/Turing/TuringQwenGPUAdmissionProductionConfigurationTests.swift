import TuringQwenNative
import XCTest

@testable import Gravitas_Plague

final class TuringQwenGPUAdmissionProductionConfigurationTests: XCTestCase {
    func testBuildConfigurationSelectsOnlyTheApprovedMode() throws {
        let configuration = try
            TuringQwenGPUAdmissionExperimentConfiguration.current(arguments: [])
        #if GR_TURING_DECODE_EXCLUSIVE
        XCTAssertEqual(configuration.mode, .decodeExclusive)
        #else
        XCTAssertEqual(configuration.mode, .currentOverlap)
        #endif

        let policy = try configuration.policy()
        XCTAssertEqual(policy.maximumConcurrentGenerationLeases, 2)
        XCTAssertTrue(policy.decoderHasPriority)
    }

    func testProductionDoesNotExposeACommandLineModeOverride() throws {
        let configuration = try
            TuringQwenGPUAdmissionExperimentConfiguration.current(
                arguments: ["--turing-gpu-admission=decodeExclusive"]
            )
        #if GR_TURING_DECODE_EXCLUSIVE || GR_TURING_QUALIFICATION
        XCTAssertEqual(configuration.mode, .decodeExclusive)
        #else
        XCTAssertEqual(configuration.mode, .currentOverlap)
        #endif
    }

    #if GR_TURING_QUALIFICATION && !GR_TURING_DECODE_EXCLUSIVE
    func testQualificationRejectsAnUnknownMode() {
        XCTAssertThrowsError(
            try TuringQwenGPUAdmissionExperimentConfiguration.current(
                arguments: ["--turing-gpu-admission=unknown"]
            )
        )
    }
    #endif
}
