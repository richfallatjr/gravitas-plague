import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionCaptureManifestTests: XCTestCase {
    func testManifestJSONRoundTripPreservesFrameZeroContract() throws {
        let manifest = mindEyeProjectionManifestFixture()
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MindEyeProjectionCaptureManifest.self, from: encoded)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.captureState, "frameZero")
        XCTAssertEqual(decoded.animationAdvancedFrames, 0)
        XCTAssertEqual(decoded.mediaTimeSeconds, 0)
    }
}
