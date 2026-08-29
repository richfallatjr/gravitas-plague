import XCTest

@testable import Gravitas_Plague

final class MindEyeChapter03MikeSuppressionTests: XCTestCase {
    func testChapter03AcquiresAllPresentationClaimBeforePhysicalMikeStart() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/Chapter03Coordinator.swift"
        )
        XCTAssertTrue(source.contains("physicalMikePresenceLease"))
        XCTAssertTrue(source.contains("scope: .allPresentations"))
        XCTAssertTrue(source.contains("sourceID: \"chapter03.mikeBattle."))

        let acquire = try XCTUnwrap(source.range(of: "acquirePhysicalMikePresence("))
        let start = try XCTUnwrap(source.range(of: "mikeBattle.prepareAndStart("))
        XCTAssertLessThan(acquire.lowerBound, start.lowerBound)
    }

    func testChapter03HasSuccessFailureCancelAndDefensiveReleasePaths() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/Chapter03Coordinator.swift"
        )
        for reason in [
            "chapter03.mikeBattle.released",
            "chapter03.mikeBattle.failed",
            "chapter03.endCardRouteCommitted",
            "chapter03.cancel.",
            "chapter03.failure"
        ] {
            XCTAssertTrue(source.contains(reason), reason)
        }
    }
}
