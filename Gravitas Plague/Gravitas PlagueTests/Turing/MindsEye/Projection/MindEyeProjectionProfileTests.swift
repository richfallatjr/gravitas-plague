import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionProfileTests: XCTestCase {
    func testCanonicalSquareProfileValidates() throws {
        let profile = try mindEyeProjectionProfileFixture()
        XCTAssertNoThrow(try profile.validate())
        XCTAssertEqual(profile.sourceWidth * profile.sourceHeight, 2_304 * 1_296)
        XCTAssertEqual(profile.viewportWidth * profile.viewportHeight, 1_920 * 1_080)
        XCTAssertEqual(profile.cropOriginX, 144)
        XCTAssertEqual(profile.cropOriginY, 144)
        XCTAssertEqual(
            profile.projectionMaskResourcePath,
            "Turing/MindsEye/Projection/masks/angel_head_v1_projection-mask-linear16.png"
        )
        XCTAssertEqual(
            profile.plateManifestResourcePath,
            "Turing/MindsEye/Projection/plates/angel_head_v1/source-manifest.json"
        )
        XCTAssertEqual(profile.projectionMaskSHA256.count, 64)
        XCTAssertEqual(profile.projectionMaskConvention, "whiteProjectsBlackSuppresses")
    }
}
