import XCTest

@testable import Gravitas_Plague

final class MindEyePhase11NoShippingDiagnosticsTests: XCTestCase {
    func testProductionFeatureModeIgnoresQualificationLaunchArguments() throws {
        let source = try MindEyePhase11TestSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeReleaseScenario.swift"
        )
        let condition = try XCTUnwrap(source.range(of: "#if GR_MIND_EYE_QUALIFICATION"))
        let argument = try XCTUnwrap(source.range(of: "--mind-eye-qualification-mode="))
        let fallback = try XCTUnwrap(source.range(of: "#else", range: argument.lowerBound..<source.endIndex))
        XCTAssertLessThan(condition.lowerBound, argument.lowerBound)
        XCTAssertLessThan(argument.lowerBound, fallback.lowerBound)
        XCTAssertTrue(source[fallback.lowerBound...].contains("return .enabled"))
    }
}
