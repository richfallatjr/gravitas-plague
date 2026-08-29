import XCTest
import simd

@testable import Gravitas_Plague

final class MindEyeSmoothRandomTests: XCTestCase {
    func testSmootherstepEndpointsAndFlatEndpointDerivatives() {
        XCTAssertEqual(MindEyeSmootherstep.evaluate(0), 0)
        XCTAssertEqual(MindEyeSmootherstep.evaluate(1), 1)
        XCTAssertEqual(MindEyeSmootherstep.evaluate(-1), 0)
        XCTAssertEqual(MindEyeSmootherstep.evaluate(2), 1)
        let epsilon: Float = 0.0001
        XCTAssertLessThan(MindEyeSmootherstep.evaluate(epsilon) / epsilon, 0.001)
        XCTAssertLessThan(
            (1 - MindEyeSmootherstep.evaluate(1 - epsilon)) / epsilon,
            0.001
        )
    }

    func testDriftAndSubjectChannelsRemainNormalized() {
        var random = MindEyeDeterministicRandom(seed: 91)
        var drift = MindEyeDriftChannel()
        var subject = MindEyeSubjectChannel()
        for _ in 0..<2_000 {
            drift.advance(
                deltaTime: 1 / 60,
                random: &random,
                transitionRange: 0.2...0.5,
                holdRange: 0...0.2
            )
            subject.advance(
                deltaTime: 1 / 60,
                random: &random,
                transitionRange: 0.2...0.5,
                holdRange: 0...0.2
            )
            XCTAssertTrue(drift.current.indices.allSatisfy { abs(drift.current[$0]) <= 1 })
            XCTAssertTrue(subject.current.indices.allSatisfy { abs(subject.current[$0]) <= 1 })
        }
    }

    func testGripCorrectionSettlesExactlyToZero() {
        var random = MindEyeDeterministicRandom(seed: 123)
        var grip = MindEyeGripCorrectionChannel(
            random: &random,
            waitingRange: 0.1...0.1
        )
        var sawCorrection = false
        for _ in 0..<200 {
            grip.advance(
                deltaTime: 0.01,
                random: &random,
                waitingRange: 10...10,
                onsetRange: 0.1...0.1,
                settleRange: 0.2...0.2
            )
            sawCorrection = sawCorrection || grip.current != .zero
        }
        XCTAssertTrue(sawCorrection)
        XCTAssertEqual(grip.correctionCount, 1)
        XCTAssertEqual(grip.current, .zero)
    }
}
