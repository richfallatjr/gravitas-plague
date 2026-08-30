import simd
import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionCameraDescriptorTests: XCTestCase {
    func testCanonicalCameraRoundTripsAndComposesClipTransform() throws {
        let camera = try mindEyeProjectionCameraFixture()
        try camera.validate()
        let encoded = try JSONEncoder().encode(camera)
        let decoded = try JSONDecoder().decode(MindEyeProjectionCameraDescriptor.self, from: encoded)
        XCTAssertEqual(decoded, camera)
        let expected = camera.clipFromCameraMatrix * camera.subjectFromCameraMatrix.inverse
        for (actual, wanted) in zip(camera.clipFromSubject, expected.columnMajorValues) {
            XCTAssertEqual(actual, wanted, accuracy: 0.000_01)
        }
    }

    func testCameraTargetsSquareCrop() throws {
        let camera = try mindEyeProjectionCameraFixture()
        XCTAssertEqual(camera.sourceCropOrigin, [144, 144])
        XCTAssertEqual(camera.sourceCropSize, [1_440, 1_440])
    }
}
