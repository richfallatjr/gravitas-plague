import XCTest
import simd

@testable import Gravitas_Plague

final class MindEyeMotionModelTests: XCTestCase {
    func testSameSeedAndTimeStepProduceIdenticalTrace() throws {
        XCTAssertEqual(
            try trace(seed: 41, count: 1_000, deltaTime: 1 / 60),
            try trace(seed: 41, count: 1_000, deltaTime: 1 / 60)
        )
        XCTAssertNotEqual(
            try trace(seed: 41, count: 10, deltaTime: 1 / 60),
            try trace(seed: 42, count: 10, deltaTime: 1 / 60)
        )
    }

    func testFirstSampleEasesAwayFromRestAndAllSamplesAreFinite() throws {
        let samples = try trace(seed: 7, count: 1_000, deltaTime: 1 / 60)
        let first = try XCTUnwrap(samples.first)
        XCTAssertLessThan(length(first.characterTransform.translationPixels), 0.01)
        for sample in samples {
            XCTAssertTrue(sample.backgroundTransform.isFiniteAndPositive)
            XCTAssertTrue(sample.characterTransform.isFiniteAndPositive)
            XCTAssertLessThan(abs(sample.characterTransform.translationPixels.x), 100)
            XCTAssertLessThan(abs(sample.characterTransform.translationPixels.y), 100)
        }
    }

    func testMaximumDeltaIsClamped() throws {
        let tuning = makePhaseFiveTestTuning()
        var large = MindEyeMotionRuntimeState(rootSeed: 99, tuning: tuning)
        var clamped = MindEyeMotionRuntimeState(rootSeed: 99, tuning: tuning)
        let largeSample = try MindEyeMotionModel.advance(
            state: &large,
            deltaTime: 10,
            tuning: tuning
        ).get()
        let clampedSample = try MindEyeMotionModel.advance(
            state: &clamped,
            deltaTime: TimeInterval(tuning.maximumSimulationStepSeconds),
            tuning: tuning
        ).get()
        XCTAssertEqual(largeSample, clampedSample)
    }

    func testNotAdvancingLeavesStateFrozen() {
        let tuning = makePhaseFiveTestTuning()
        let state = MindEyeMotionRuntimeState(rootSeed: 5, tuning: tuning)
        let copy = state
        XCTAssertEqual(state, copy)
    }

    private func trace(
        seed: UInt64,
        count: Int,
        deltaTime: TimeInterval
    ) throws -> [MindEyeMotionRenderSample] {
        let tuning = makePhaseFiveTestTuning()
        var state = MindEyeMotionRuntimeState(rootSeed: seed, tuning: tuning)
        return try (0..<count).map { _ in
            try MindEyeMotionModel.advance(
                state: &state,
                deltaTime: deltaTime,
                tuning: tuning
            ).get()
        }
    }
}

func makePhaseFiveTestTuning() -> MindEyeKeepAliveTuning {
    MindEyeKeepAliveTuning(
        characterDepthMeters: 0.75,
        backgroundDepthMeters: 3,
        sharedDriftMaxPixels: [36, 20],
        sharedRollMaxRadians: 0.55 * .pi / 180,
        sharedScaleMax: 1.018,
        characterParallaxMaxPixels: [18, 10],
        characterScaleDeltaMax: 0.003,
        backgroundCounterMotion: 0.28,
        gripCorrectionMaxPixels: [24, 14],
        gripCorrectionMaxRadians: 0.25 * .pi / 180,
        driftTransitionSeconds: 0.9...2.6,
        driftHoldSeconds: 0...0.8,
        subjectTransitionSeconds: 1.2...3.8,
        subjectHoldSeconds: 0...1,
        gripWaitingSeconds: 7...18,
        gripOnsetSeconds: 0.18...0.35,
        gripSettleSeconds: 0.6...1.2,
        maximumSimulationStepSeconds: 1 / 15,
        blink: MindEyeResolvedBlinkTuning(
            ordinaryIntervalSeconds: 2...5,
            closedReferenceFrames: 5...8,
            doubleBlinkProbability: 0.08,
            doubleBlinkGapSeconds: 0.5...1,
            referenceFrameRate: 60
        ),
        projection: MindEyeProjectionTuning(
            outputSizePixels: [1_920, 1_080],
            horizontalFOVRadians: 62 * .pi / 180,
            driftRotationShare: 0.72,
            gripRotationShare: 0.55
        ),
        openEyeVariantCount: 2,
        closedEyeVariantCount: 2
    )
}
