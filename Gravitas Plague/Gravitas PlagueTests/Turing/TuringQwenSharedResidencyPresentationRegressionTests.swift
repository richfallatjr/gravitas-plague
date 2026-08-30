import XCTest

@testable import Gravitas_Plague

final class TuringQwenSharedResidencyPresentationRegressionTests: XCTestCase {
    func testMindEyeContinuityPreflightStillPrecedesQwenPoolCreation() throws {
        let source = try Phase3AppSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/Flow/" +
                "TuringCharacterQwenRenderSession.swift"
        )
        let preflight = try XCTUnwrap(
            source.range(of: "prepareForTuringHighMemoryRun")
        )
        let pool = try XCTUnwrap(
            source.range(of: ".makeFresh2Pool(")
        )
        XCTAssertLessThan(preflight.lowerBound, pool.lowerBound)
        XCTAssertTrue(source.contains("spokenPresentationContinuity"))
    }
}
