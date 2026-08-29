import XCTest

@testable import Gravitas_Plague

final class MindEyeMemoryPressureTests: XCTestCase {
    func testPressureLevelsRemainDistinct() {
        XCTAssertEqual(MindEyeMemoryPressureLevel.normal.rawValue, "normal")
        XCTAssertEqual(MindEyeMemoryPressureLevel.warning.rawValue, "warning")
        XCTAssertEqual(MindEyeMemoryPressureLevel.critical.rawValue, "critical")
    }

    func testWarningEvictsInactiveAndCriticalPreservesMindEye() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeLifecycleCoordinator.swift"
        )
        let warning = try XCTUnwrap(source.range(of: "case .warning:"))
        let critical = try XCTUnwrap(source.range(of: "case .critical:", range: warning.upperBound..<source.endIndex))
        let warningBody = String(source[warning.lowerBound..<critical.lowerBound])
        let criticalBody = String(source[critical.lowerBound...])
        XCTAssertTrue(warningBody.contains("releasePreparedAndEvictInactive"))
        XCTAssertFalse(warningBody.contains("releaseAllPresentationState"))
        XCTAssertTrue(criticalBody.contains("action=noTeardown"))
        XCTAssertFalse(criticalBody.contains("scope: .memoryCritical"))
        XCTAssertFalse(
            criticalBody.contains("forceEvictAll(reason: \"memoryPressure.critical\")")
        )
        XCTAssertFalse(
            criticalBody.contains(
                "clearRegistriesAfterTeardown(reason: \"memoryPressure.critical\")"
            )
        )
        XCTAssertFalse(criticalBody.contains("handleMemoryPressure(level)"))
    }
}
