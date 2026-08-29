import XCTest

@testable import Gravitas_Plague

final class MindEyeVisualSuspensionTests: XCTestCase {
    func testSuspensionReasonsRemainIndependent() {
        XCTAssertNotEqual(
            MindEyeVisualSuspensionReason.audioPaused,
            .applicationInactive
        )
        XCTAssertNotEqual(
            MindEyeVisualSuspensionReason.applicationInactive,
            .lifecycleTransition
        )
    }

    func testDynamicSurfaceFreezesBothPlaybackRegistriesAndResamplesOnResume() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeDynamicOutputSurface.swift"
        )
        XCTAssertTrue(source.contains("Set<MindEyeVisualSuspensionReason>"))
        XCTAssertTrue(source.contains("setPresentationSuspended("))
        XCTAssertTrue(source.contains("resampleAt:"))
        XCTAssertTrue(source.contains("suspensionReasons.contains(.applicationInactive)"))
        XCTAssertTrue(source.contains("suspensionReasons.contains(.lifecycleTransition)"))
    }
}
