import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionRoundTripTests: XCTestCase {
    func testPublishedCameraContainsNoNegativeZeroOrPlaceholder() throws {
        let data = try mindEyeProjectionResourceData(
            "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json"
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("-0,"))
        XCTAssertFalse(text.contains("<Codex"))
        XCTAssertNoThrow(try JSONDecoder().decode(MindEyeProjectionCameraDescriptor.self, from: data).validate())
    }
}
