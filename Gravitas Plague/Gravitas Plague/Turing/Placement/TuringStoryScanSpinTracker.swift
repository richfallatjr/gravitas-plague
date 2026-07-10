import Foundation
import simd

enum TuringStoryScanSpinDirection: String, Codable, Sendable {
    case clockwise
    case counterClockwise

    var promptValue: String {
        self == .clockwise ? "cw" : "ccw"
    }
}

struct TuringStoryScanSpinResult: Sendable {
    let startYawRadians: Float
    let accumulatedYawRadians: Float
    let direction: TuringStoryScanSpinDirection
}

@MainActor
final class TuringStoryScanSpinTracker {
    private(set) var startYawRadians: Float?
    private(set) var previousYawRadians: Float?
    private(set) var accumulatedYawRadians: Float = 0
    private(set) var sampleCount: Int = 0

    func begin(headForward: SIMD3<Float>) {
        reset()
        let yaw = Self.yaw(headForward)
        startYawRadians = yaw
        previousYawRadians = yaw
        sampleCount = 1
    }

    func update(headForward: SIMD3<Float>) {
        let yaw = Self.yaw(headForward)
        guard let previousYawRadians else {
            begin(headForward: headForward)
            return
        }
        accumulatedYawRadians += Self.unwrappedDelta(
            from: previousYawRadians,
            to: yaw
        )
        self.previousYawRadians = yaw
        sampleCount += 1
    }

    func finish() throws -> TuringStoryScanSpinResult {
        guard let startYawRadians, sampleCount > 1 else {
            throw NSError(
                domain: "TuringStoryScanSpinTracker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Story scan spin had insufficient pose samples."]
            )
        }
        return TuringStoryScanSpinResult(
            startYawRadians: startYawRadians,
            accumulatedYawRadians: accumulatedYawRadians,
            direction: accumulatedYawRadians >= 0 ? .counterClockwise : .clockwise
        )
    }

    func reset() {
        startYawRadians = nil
        previousYawRadians = nil
        accumulatedYawRadians = 0
        sampleCount = 0
    }

    private static func yaw(_ forward: SIMD3<Float>) -> Float {
        atan2(forward.x, forward.z)
    }

    private static func unwrappedDelta(from lhs: Float, to rhs: Float) -> Float {
        var delta = rhs - lhs
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
