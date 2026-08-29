import XCTest

@testable import Gravitas_Plague

final class MindEyeProviderTeardownTests: XCTestCase {
    func testWalkieInvalidatesProviderBeforeRemovingRootChildren() throws {
        try assertInvalidationBeforeRemoval(
            path: "Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift",
            invalidation: "invalidateMindEyePlacement(reason: \"wallBundleReset.",
            removal: "root.children.removeAll()"
        )
    }

    func testRollingBenchInvalidatesBeforeResetAndUnloadRemoval() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/Props/TuringRollingBenchBundleController.swift"
        )
        let reset = try XCTUnwrap(source.range(of: "invalidateMindEyePlacement(reason: \"rollingBenchReset."))
        let unload = try XCTUnwrap(source.range(of: "func unload(reason: String)"))
        XCTAssertLessThan(reset.lowerBound, unload.lowerBound)
        XCTAssertTrue(String(source[unload.lowerBound...]).contains("reset(reason: reason)"))
    }

    private func assertInvalidationBeforeRemoval(
        path: String,
        invalidation: String,
        removal: String
    ) throws {
        let source = try MindEyePhase10Source.read(path)
        let invalidationRange = try XCTUnwrap(source.range(of: invalidation))
        let removalRange = try XCTUnwrap(source.range(of: removal))
        XCTAssertLessThan(invalidationRange.lowerBound, removalRange.lowerBound)
    }
}
