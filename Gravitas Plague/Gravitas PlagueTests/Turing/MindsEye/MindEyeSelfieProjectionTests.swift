import XCTest
import simd

@testable import Gravitas_Plague

final class MindEyeSelfieProjectionTests: XCTestCase {
    func testIdentityProjectsToIdentity() throws {
        let result = try MindEyeSelfieProjection.project(
            camera: .identity,
            subject: .identity,
            tuning: makePhaseFiveTestTuning()
        ).get()
        XCTAssertEqual(result.backgroundTransform, .identity)
        XCTAssertEqual(result.characterTransform, .identity)
    }

    func testCameraTranslationPreservesDepthParallax() throws {
        var camera = MindEyeVirtualCameraPose.identity
        camera.translationMeters = [0.02, 0.02, 0.05]
        let result = try MindEyeSelfieProjection.project(
            camera: camera,
            subject: .identity,
            tuning: makePhaseFiveTestTuning()
        ).get()
        XCTAssertLessThan(result.characterTransform.translationPixels.x, 0)
        XCTAssertLessThan(result.backgroundTransform.translationPixels.x, 0)
        XCTAssertGreaterThan(
            abs(result.characterTransform.translationPixels.x),
            abs(result.backgroundTransform.translationPixels.x)
        )
        XCTAssertLessThan(result.characterTransform.translationPixels.y, 0)
        XCTAssertLessThan(result.backgroundTransform.translationPixels.y, 0)
        XCTAssertGreaterThan(
            result.characterTransform.scale,
            result.backgroundTransform.scale
        )
    }

    func testRotationIsDepthIndependentAndContentRollIsOpposed() throws {
        var camera = MindEyeVirtualCameraPose.identity
        camera.yawRadians = 0.02
        camera.pitchRadians = -0.01
        camera.rollRadians = 0.03
        let result = try MindEyeSelfieProjection.project(
            camera: camera,
            subject: .identity,
            tuning: makePhaseFiveTestTuning()
        ).get()
        XCTAssertEqual(
            result.characterTransform.translationPixels.x,
            result.backgroundTransform.translationPixels.x,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            result.characterTransform.translationPixels.y,
            result.backgroundTransform.translationPixels.y,
            accuracy: 0.0001
        )
        XCTAssertLessThan(result.characterTransform.rollRadians, 0)
        XCTAssertEqual(
            result.characterTransform.rollRadians,
            result.backgroundTransform.rollRadians
        )
    }

    func testSubjectMotionMovesForegroundAndCounterMovesBackground() throws {
        let tuning = makePhaseFiveTestTuning()
        let subject = MindEyeSubjectRelativePose(
            translationMeters: [0.01, 0],
            scaleDelta: 0.002
        )
        let result = try MindEyeSelfieProjection.project(
            camera: .identity,
            subject: subject,
            tuning: tuning
        ).get()
        XCTAssertGreaterThan(result.characterTransform.translationPixels.x, 0)
        XCTAssertLessThan(result.backgroundTransform.translationPixels.x, 0)
        XCTAssertEqual(
            result.backgroundTransform.translationPixels.x,
            -result.subjectOffsetPixels.x * tuning.backgroundCounterMotion,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(result.characterTransform.scale, 1)
    }
}
