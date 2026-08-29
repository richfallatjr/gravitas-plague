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
        XCTAssertTrue(source.contains("policy: .retainActivePresentation"))
    }

    func testRetentionPoliciesAreExplicit() {
        XCTAssertNotEqual(
            MindEyeActiveHighMemoryRetentionPolicy.retainMatchingRunActive,
            .releaseAll
        )
        XCTAssertNotEqual(
            MindEyeActiveHighMemoryRetentionPolicy.retainActivePresentation,
            .releaseAll
        )
    }

    func testAuthoredParentCanHandItsPortraitToGeneratedChildRun() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/" +
                "MindEyePresentationCoordinator.swift"
        )
        XCTAssertTrue(source.contains("PendingGeneratedContinuity"))
        XCTAssertTrue(source.contains("canPromoteGeneratedContinuity"))
        XCTAssertTrue(source.contains("settleAuthoredPortraitForGeneratedContinuity"))
        XCTAssertTrue(source.contains("cardRebuilt=false"))
    }
}
