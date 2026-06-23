//
//  Gravitas_PlagueTests.swift
//  Gravitas PlagueTests
//
//  Created by Richard Fallat on 5/31/26.
//

import XCTest
import simd

final class Gravitas_PlagueTests: XCTestCase {
    func testForearmJointUsesUpperArmLengthRatio() throws {
        let scale = try exactJointTranslationScale(
            sourceLength: 0.30,
            targetLength: 0.45
        )

        XCTAssertEqual(scale, 1.5, accuracy: 0.0001)
    }

    func testHandJointUsesForearmLengthRatio() throws {
        let scale = try exactJointTranslationScale(
            sourceLength: 0.40,
            targetLength: 0.30
        )

        XCTAssertEqual(scale, 0.75, accuracy: 0.0001)
    }

    func testGlobalHeightDoesNotAffectNonRootTranslation() throws {
        let sourceDelta = SIMD3<Float>(0.02, 0.04, -0.01)
        let scale = try exactJointTranslationScale(
            sourceLength: 0.25,
            targetLength: 0.50
        )

        let lowHeightResult = retargetedNonRootTranslationDelta(
            sourceDelta,
            exactJointScale: scale,
            ignoredGlobalHeightScale: 0.5
        )
        let highHeightResult = retargetedNonRootTranslationDelta(
            sourceDelta,
            exactJointScale: scale,
            ignoredGlobalHeightScale: 3.0
        )

        XCTAssertEqual(lowHeightResult.x, highHeightResult.x, accuracy: 0.0001)
        XCTAssertEqual(lowHeightResult.y, highHeightResult.y, accuracy: 0.0001)
        XCTAssertEqual(lowHeightResult.z, highHeightResult.z, accuracy: 0.0001)
    }

    func testMultiplierIsNotClamped() throws {
        let scale = try exactJointTranslationScale(
            sourceLength: 0.10,
            targetLength: 0.70
        )

        XCTAssertEqual(scale, 7.0, accuracy: 0.0001)
    }

    func testMissingBoneLengthFailsValidation() {
        XCTAssertThrowsError(
            try exactJointTranslationScale(
                sourceLength: nil,
                targetLength: 0.40
            )
        )

        XCTAssertThrowsError(
            try exactJointTranslationScale(
                sourceLength: 0.40,
                targetLength: nil
            )
        )
    }

    func testZeroLengthBoneFailsValidation() {
        XCTAssertThrowsError(
            try exactJointTranslationScale(
                sourceLength: 0,
                targetLength: 0.40
            )
        )

        XCTAssertThrowsError(
            try exactJointTranslationScale(
                sourceLength: 0.40,
                targetLength: 0
            )
        )
    }

    func testRootTranslationDoesNotUseJointScaleMap() throws {
        XCTAssertFalse(
            shouldUseJointTranslationScale(
                joint: "Hips",
                hasTranslation: true
            )
        )
    }

    func testAbsoluteAndAdditiveTranslationUseSameMultiplier() throws {
        let scale = try exactJointTranslationScale(
            sourceLength: 0.20,
            targetLength: 0.50
        )
        let delta = SIMD3<Float>(0.01, 0.02, 0.03)

        let absolute = retargetedNonRootTranslationDelta(
            delta,
            exactJointScale: scale,
            ignoredGlobalHeightScale: 1.0
        )
        let additive = retargetedNonRootTranslationDelta(
            delta,
            exactJointScale: scale,
            ignoredGlobalHeightScale: 10.0
        )

        XCTAssertEqual(absolute.x, additive.x, accuracy: 0.0001)
        XCTAssertEqual(absolute.y, additive.y, accuracy: 0.0001)
        XCTAssertEqual(absolute.z, additive.z, accuracy: 0.0001)
    }

    func testRotationOutputIsUnchanged() throws {
        let sourceRotation = simd_quatf(
            angle: 0.35,
            axis: SIMD3<Float>(0, 1, 0)
        )

        XCTAssertEqual(
            sourceRotation.vector.x,
            sourceRotationUnchangedByTranslationScale(sourceRotation).vector.x,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            sourceRotation.vector.y,
            sourceRotationUnchangedByTranslationScale(sourceRotation).vector.y,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            sourceRotation.vector.z,
            sourceRotationUnchangedByTranslationScale(sourceRotation).vector.z,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            sourceRotation.vector.w,
            sourceRotationUnchangedByTranslationScale(sourceRotation).vector.w,
            accuracy: 0.0001
        )
    }

    func testAlternatingHandsCanHitWithoutCooldown() {
        var left = TestHandImpactLatch()
        var right = TestHandImpactLatch()

        XCTAssertTrue(
            consumeImpact(
                &left,
                distance: 0.20,
                radialVelocity: -1.0
            )
        )
        XCTAssertTrue(
            consumeImpact(
                &right,
                distance: 0.20,
                radialVelocity: -1.0
            )
        )
    }

    func testSameHandCanHitAgainAfterImmediateRetraction() {
        var latch = TestHandImpactLatch()

        XCTAssertTrue(
            consumeImpact(
                &latch,
                distance: 0.20,
                radialVelocity: -1.0
            )
        )

        latch.rearmIfNeeded(
            distance: 0.20,
            radialVelocity: 0.25,
            maxHitDistance: 0.40
        )

        XCTAssertTrue(
            consumeImpact(
                &latch,
                distance: 0.20,
                radialVelocity: -1.0
            )
        )
    }

    func testContinuousInwardOverlapDoesNotHitEveryFrame() {
        var latch = TestHandImpactLatch()

        XCTAssertTrue(
            consumeImpact(
                &latch,
                distance: 0.20,
                radialVelocity: -1.0
            )
        )
        XCTAssertFalse(
            consumeImpact(
                &latch,
                distance: 0.19,
                radialVelocity: -0.9
            )
        )
    }
}

private enum TestTranslationScaleError: Error {
    case missingLength
    case invalidLength
}

private func exactJointTranslationScale(
    sourceLength: Float?,
    targetLength: Float?
) throws -> Float {
    guard let sourceLength,
          let targetLength else {
        throw TestTranslationScaleError.missingLength
    }

    guard sourceLength > 0.0001,
          targetLength > 0.0001 else {
        throw TestTranslationScaleError.invalidLength
    }

    return targetLength / sourceLength
}

private func retargetedNonRootTranslationDelta(
    _ sourceDelta: SIMD3<Float>,
    exactJointScale: Float,
    ignoredGlobalHeightScale: Float
) -> SIMD3<Float> {
    _ = ignoredGlobalHeightScale
    return sourceDelta * exactJointScale
}

private func shouldUseJointTranslationScale(
    joint: String,
    hasTranslation: Bool
) -> Bool {
    hasTranslation && joint != "Hips"
}

private func sourceRotationUnchangedByTranslationScale(
    _ rotation: simd_quatf
) -> simd_quatf {
    rotation
}

private func consumeImpact(
    _ latch: inout TestHandImpactLatch,
    distance: Float,
    radialVelocity: Float
) -> Bool {
    latch.rearmIfNeeded(
        distance: distance,
        radialVelocity: radialVelocity,
        maxHitDistance: 0.40
    )

    let accepted = latch.canAcceptImpact(
        distance: distance,
        approachSpeed: -radialVelocity,
        maxHitDistance: 0.40,
        minimumApproachSpeed: 0.55
    )

    if accepted {
        latch.consumeAcceptedImpact()
    }

    return accepted
}

private struct TestHandImpactLatch {
    private(set) var isArmed = true

    mutating func rearmIfNeeded(
        distance: Float,
        radialVelocity: Float,
        maxHitDistance: Float
    ) {
        if distance > maxHitDistance ||
            radialVelocity >= 0 {
            isArmed = true
        }
    }

    func canAcceptImpact(
        distance: Float,
        approachSpeed: Float,
        maxHitDistance: Float,
        minimumApproachSpeed: Float
    ) -> Bool {
        isArmed &&
            distance <= maxHitDistance &&
            approachSpeed >= minimumApproachSpeed
    }

    mutating func consumeAcceptedImpact() {
        isArmed = false
    }
}
