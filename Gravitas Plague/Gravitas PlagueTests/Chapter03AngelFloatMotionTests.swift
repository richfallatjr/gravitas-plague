import XCTest
import simd

@testable import Gravitas_Plague

final class Chapter03AngelFloatMotionTests: XCTestCase {
    func testMaximumFloatDistanceIsExactlyTwelveInches() {
        XCTAssertEqual(
            Chapter03AngelFloatMotion.maxOffsetMeters,
            0.3048,
            accuracy: 0.000_001
        )
    }

    func testFloatMotionNeverLeavesTwelveInchSphere() {
        var motion = Chapter03AngelFloatMotion(seed: 0xCAFE_BABE)

        for _ in 0..<(60 * 600) {
            let offset = motion.update(deltaTime: 1.0 / 60.0)
            XCTAssertLessThanOrEqual(
                simd_length(offset),
                Chapter03AngelFloatMotion.maxOffsetMeters + 0.000_001
            )
        }
    }

    func testFloatMotionIsDeterministicForASeed() {
        var first = Chapter03AngelFloatMotion(seed: 42)
        var second = Chapter03AngelFloatMotion(seed: 42)

        for _ in 0..<2_000 {
            XCTAssertEqual(
                first.update(deltaTime: 1.0 / 60.0),
                second.update(deltaTime: 1.0 / 60.0)
            )
        }
    }

    func testFloatMotionExploresBothDirectionsOnEveryAxis() {
        var motion = Chapter03AngelFloatMotion(seed: 0xB10F_5EED)
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for _ in 0..<(60 * 600) {
            let offset = motion.update(deltaTime: 1.0 / 60.0)
            minimum = simd_min(minimum, offset)
            maximum = simd_max(maximum, offset)
        }

        XCTAssertLessThan(minimum.x, 0)
        XCTAssertLessThan(minimum.y, 0)
        XCTAssertLessThan(minimum.z, 0)
        XCTAssertGreaterThan(maximum.x, 0)
        XCTAssertGreaterThan(maximum.y, 0)
        XCTAssertGreaterThan(maximum.z, 0)
    }

    func testPerFrameMovementStaysSoftAtSixtyFramesPerSecond() {
        var motion = Chapter03AngelFloatMotion(seed: 0x50F7)
        var previous = SIMD3<Float>.zero

        for _ in 0..<(60 * 600) {
            let offset = motion.update(deltaTime: 1.0 / 60.0)
            XCTAssertLessThan(simd_distance(previous, offset), 0.003)
            previous = offset
        }
    }
}
