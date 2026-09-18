import Foundation
import XCTest
@testable import MLX

final class TuringMLXBuildFingerprintTests: XCTestCase {
    func testAllocatorFingerprintIsCompiledAndRoundTrips() throws {
        let value = try TuringMLXBuildFingerprint.current
        XCTAssertEqual(value.schemaVersion, 1)
        XCTAssertEqual(value.translationUnit, "mlx/mlx/backend/metal/allocator.cpp")
        XCTAssertTrue(["fast", "extensive", "debug", "none"].contains(value.hardeningMode))
        XCTAssertEqual(value.internalAssertionsEnabled, value.hardeningMode == "debug")
        XCTAssertNotEqual(value.compiler, "unknown")
        XCTAssertNotNil(value.libcxxVersion)
        XCTAssertEqual(try JSONDecoder().decode(TuringMLXBuildFingerprint.self,
            from: JSONEncoder().encode(value)), value)
    }
}
