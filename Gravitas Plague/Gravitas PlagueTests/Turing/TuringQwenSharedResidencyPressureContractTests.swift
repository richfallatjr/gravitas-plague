import XCTest

@testable import Gravitas_Plague

final class TuringQwenSharedResidencyPressureContractTests: XCTestCase {
    func testSharedTopologyHasNoAutomaticIndependentOrOneLaneFallback() throws {
        let source = try Phase3AppSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/" +
                "TuringQwenNative/TuringQwenNativeFreshInstancePool.swift"
        )
        XCTAssertTrue(source.contains("fallbackAllowed == false"))
        XCTAssertTrue(source.contains("requestedInstanceCount == 2"))
        XCTAssertFalse(source.contains("fallbackAllowed: true"))
    }

    func testSharedTeardownOwnsOneFinalCacheClear() throws {
        let source = try Phase3AppSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/" +
                "TuringQwenNative/TuringQwenNativeFreshInstancePool.swift"
        )
        XCTAssertTrue(source.contains("sharedResidency.ownerReleased"))
        XCTAssertTrue(source.contains("receipts.removeAll"))
        XCTAssertTrue(source.contains("owner.finish"))
    }
}
