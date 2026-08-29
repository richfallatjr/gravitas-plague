import XCTest

@testable import Gravitas_Plague

final class MindEyeHighMemoryPreflightTests: XCTestCase {
    func testMindEyePreflightRunsBeforeOptionalStoryAdapterGuard() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/Memory/TuringHighMemoryPreflightCoordinator.swift"
        )
        let mindEye = try XCTUnwrap(source.range(of: "mindEyePreparer?.prepareForTuringHighMemoryRun"))
        let storyGuard = try XCTUnwrap(source.range(of: "guard let storyPreparer"))
        XCTAssertLessThan(mindEye.lowerBound, storyGuard.lowerBound)
        XCTAssertTrue(source.contains("policy: .retainMatchingRunActive"))
    }

    func testRetentionPoliciesAreExplicit() {
        XCTAssertNotEqual(
            MindEyeActiveHighMemoryRetentionPolicy.retainMatchingRunActive,
            .releaseAll
        )
    }
}
