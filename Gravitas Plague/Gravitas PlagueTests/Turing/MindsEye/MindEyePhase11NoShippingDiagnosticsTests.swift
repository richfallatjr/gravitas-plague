import XCTest

@testable import Gravitas_Plague

final class MindEyePhase11NoShippingDiagnosticsTests: XCTestCase {
    func testMainMenuDoesNotExposeDoorOrDiagnosticsControls() throws {
        let source = try MindEyePhase11TestSource.read(
            "Gravitas Plague/Gravitas Plague/PlagueOperationModePosterMenu.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "struct PlagueMainMenuTopOrnament: View")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "struct PlagueForestTopOrnament: View",
                range: start.upperBound..<source.endIndex
            )
        )
        let ornament = source[start.lowerBound..<end.lowerBound]

        XCTAssertFalse(ornament.contains("toggleForestImmersive"))
        XCTAssertFalse(ornament.contains("Export Turing diagnostics"))
        XCTAssertFalse(
            ornament.contains("TuringProductionDiagnostics.shouldOfferExport")
        )
    }

    func testDiagnosticsExportIsNeverOfferedByReleaseBuilds() throws {
        let source = try MindEyePhase11TestSource.read(
            "Gravitas Plague/Gravitas Plague/Diagnostics/TuringProductionDiagnostics.swift"
        )
        let property = try XCTUnwrap(
            source.range(of: "static var shouldOfferExport: Bool")
        )
        let releaseBranch = try XCTUnwrap(
            source.range(
                of: "#else\n        return false\n        #endif",
                range: property.lowerBound..<source.endIndex
            )
        )

        XCTAssertGreaterThan(releaseBranch.lowerBound, property.lowerBound)
    }

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
