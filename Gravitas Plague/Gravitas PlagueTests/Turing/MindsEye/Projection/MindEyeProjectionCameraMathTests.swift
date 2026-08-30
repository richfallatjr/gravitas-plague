import simd
import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionCameraMathTests: XCTestCase {
    func testSquareFitCentersTargetAndProducesFiniteRoundTrip() throws {
        let fit = try MindEyeProjectionCameraMath.fit(
            minimum: SIMD3(-0.5, -1, -0.2),
            maximum: SIMD3(0.5, 1, 0.2),
            forwardAxis: SIMD3(0, 0, -1),
            localOffset: .zero
        )
        let uv = try XCTUnwrap(MindEyeProjectionCameraMath.projectorUV(
            subjectPosition: fit.targetCenter,
            clipFromSubject: fit.clipFromSubject
        ))
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.0001)
        XCTAssertTrue(fit.clipFromSubject.columnMajorValues.allSatisfy(\.isFinite))
    }

    func testBehindCameraIsRejected() throws {
        let fit = try MindEyeProjectionCameraMath.fit(
            minimum: SIMD3(-0.5, -0.5, -0.2),
            maximum: SIMD3(0.5, 0.5, 0.2),
            forwardAxis: SIMD3(0, 0, -1),
            localOffset: .zero
        )
        let cameraPosition = SIMD3(
            fit.subjectFromCamera.columns.3.x,
            fit.subjectFromCamera.columns.3.y,
            fit.subjectFromCamera.columns.3.z
        )
        XCTAssertNil(MindEyeProjectionCameraMath.projectorUV(
            subjectPosition: cameraPosition + SIMD3(0, 0, 10),
            clipFromSubject: fit.clipFromSubject
        ))
    }

    func testOwnerCubeControlsCenterOrientationAndFraming() throws {
        let target = try mindEyeProjectionTargetFixture()
        let control = try XCTUnwrap(target.authoringFramingControl)
        let fit = try MindEyeProjectionCameraMath.fit(authoringControl: control)
        let uv = try XCTUnwrap(MindEyeProjectionCameraMath.projectorUV(
            subjectPosition: fit.targetCenter,
            clipFromSubject: fit.clipFromSubject
        ))
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(control.controlPrimPath, "/root/face_proxy/Cube_001")
        XCTAssertEqual(control.sourceAsset, "angel_posed_mouth_open_blend_01_v0001.usdz")
    }
}
