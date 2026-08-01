import Foundation
import simd
import XCTest

@testable import Gravitas_Plague

final class Chapter01DadWindowTests: XCTestCase {
    func testDadUsesEstablishedVisualCorrection() {
        XCTAssertEqual(
            JockFollowDemoConfiguration.defaultDemo
                .visualHeadingCorrectionDegrees,
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            JockFollowDemoConfiguration.defaultDemo.followForwardSign,
            -1,
            accuracy: 0.001
        )
    }

    func testRouteProducesAuthoredLeftThenRightTurnsOnFourWalls()
        throws {
        for yawDegrees in [0, 90, 180, 270] as [Float] {
            let yaw = yawDegrees * Float.pi / 180
            let rotation = simd_quatf(
                angle: yaw,
                axis: SIMD3<Float>(0, 1, 0)
            )
            let route = try makeRoute(
                rotation: rotation,
                translation: SIMD3<Float>(2.5, 1.25, -3)
            )

            let expectedTravel = rotation.act(SIMD3<Float>(1, 0, 0))
            let expectedRoomFacing = rotation.act(SIMD3<Float>(0, 0, -1))
            assertDirection(route.entryWalkWorldForward, expectedTravel)
            assertDirection(route.exitWalkWorldForward, expectedTravel)
            assertDirection(
                route.centerFacingWindowWorldForward,
                expectedRoomFacing
            )
            XCTAssertEqual(
                route.entryToCenterSignedTurnRadians,
                Float.pi / 2,
                accuracy: 0.001
            )
            XCTAssertEqual(
                route.centerToExitSignedTurnRadians,
                -Float.pi / 2,
                accuracy: 0.001
            )
        }
    }

    func testRouteSelectsCorrectPortalNormalSign() throws {
        let rotation = simd_quatf(
            angle: Float.pi / 2,
            axis: SIMD3<Float>(0, 1, 0)
        )
        let route = try makeRoute(
            rotation: rotation,
            translation: .zero,
            invertNormalCandidate: true
        )

        assertDirection(
            route.centerFacingWindowWorldForward,
            rotation.act(SIMD3<Float>(0, 0, -1))
        )
    }

    func testAdjustedWindowTransformProducesFreshWorldRoute() throws {
        let first = try makeRoute(
            rotation: simd_quatf(
                angle: 0,
                axis: SIMD3<Float>(0, 1, 0)
            ),
            translation: .zero
        )
        let secondRotation = simd_quatf(
            angle: Float.pi / 2,
            axis: SIMD3<Float>(0, 1, 0)
        )
        let second = try makeRoute(
            rotation: secondRotation,
            translation: SIMD3<Float>(4, 0, -2)
        )

        XCTAssertNotEqual(first.entryWorldPosition, second.entryWorldPosition)
        XCTAssertNotEqual(
            first.entryWalkWorldForward,
            second.entryWalkWorldForward
        )
        assertDirection(
            second.entryWalkWorldForward,
            secondRotation.act(SIMD3<Float>(1, 0, 0))
        )
    }

    func testInvalidTurnGeometryIsRejectedWithoutFallback() {
        XCTAssertThrowsError(
            try Chapter01DadWindowRouteBuilder.make(
                windowWorldTransform: matrix_identity_float4x4,
                entryWorldPosition: SIMD3<Float>(-4, 0, 0),
                centerWorldPosition: .zero,
                exitWorldPosition: SIMD3<Float>(4, 0, 0),
                portalNormalCandidateWorld: SIMD3<Float>(1, 0, 0)
            )
        )
    }

    func testRouteRejectsDegenerateSegment() {
        XCTAssertThrowsError(
            try Chapter01DadWindowRouteBuilder.make(
                windowWorldTransform: matrix_identity_float4x4,
                entryWorldPosition: SIMD3<Float>(-0.01, 0, 0),
                centerWorldPosition: .zero,
                exitWorldPosition: SIMD3<Float>(4, 0, 0),
                portalNormalCandidateWorld: SIMD3<Float>(0, 0, -1)
            )
        )
    }

    func testTurnOwnershipModesRemainDistinct() {
        XCTAssertNotEqual(
            ScriptedRootYawOwnership.runtimeDelta,
            .externalExactWorldPose
        )
    }

    private func makeRoute(
        rotation: simd_quatf,
        translation: SIMD3<Float>,
        invertNormalCandidate: Bool = false
    ) throws -> Chapter01DadWindowRouteSnapshot {
        let entry = translation + rotation.act(SIMD3<Float>(-4, 0, 0))
        let center = translation
        let exit = translation + rotation.act(SIMD3<Float>(4, 0, 0))
        let roomNormal = rotation.act(SIMD3<Float>(0, 0, -1))
        var transform = simd_float4x4(rotation)
        transform.columns.3 = SIMD4<Float>(
            translation.x,
            translation.y,
            translation.z,
            1
        )

        return try Chapter01DadWindowRouteBuilder.make(
            windowWorldTransform: transform,
            entryWorldPosition: entry,
            centerWorldPosition: center,
            exitWorldPosition: exit,
            portalNormalCandidateWorld:
                invertNormalCandidate ? -roomNormal : roomNormal
        )
    }

    private func assertDirection(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.001, file: file, line: line)
    }
}
