import XCTest

@testable import Gravitas_Plague

final class MindEyeMemoryPressureTests: XCTestCase {
    func testPressureLevelsRemainDistinct() {
        XCTAssertEqual(MindEyeMemoryPressureLevel.normal.rawValue, "normal")
        XCTAssertEqual(MindEyeMemoryPressureLevel.warning.rawValue, "warning")
        XCTAssertEqual(MindEyeMemoryPressureLevel.critical.rawValue, "critical")
    }

    func testWarningRetainsActiveAndCriticalUsesDestructiveTeardown() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeLifecycleCoordinator.swift"
        )
        let warning = try XCTUnwrap(source.range(of: "case .warning:"))
        let critical = try XCTUnwrap(source.range(of: "case .critical:", range: warning.upperBound..<source.endIndex))
        let warningBody = String(source[warning.lowerBound..<critical.lowerBound])
        let criticalBody = String(source[critical.lowerBound...])
        XCTAssertTrue(warningBody.contains("releasePreparedAndEvictInactive"))
        XCTAssertFalse(warningBody.contains("releaseAllPresentationState"))
        XCTAssertTrue(criticalBody.contains("scope: .memoryCritical"))
        XCTAssertTrue(criticalBody.contains("forceEvictAll"))
        XCTAssertTrue(criticalBody.contains("clearRegistriesAfterTeardown"))
    }
}
