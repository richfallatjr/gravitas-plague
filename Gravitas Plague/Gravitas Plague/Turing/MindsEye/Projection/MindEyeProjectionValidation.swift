import Foundation

nonisolated enum MindEyeProjectionValidation {
    struct MaskMetrics: Sendable, Equatable {
        let coverageFraction: Double
        let boundingBox: [Int]
        let centerErrorPixels: [Double]
        let touchesEdge: Bool
    }

    static func validateMask(_ metrics: MaskMetrics, width: Int = 1_728, height: Int = 1_728) throws {
        // The owner-authored framing cube deliberately uses the 1.12 camera-fit
        // padding, whose theoretical square occupancy is just under 80%. Keep
        // rejecting clipped/full-frame captures while allowing that tighter,
        // deterministic head framing.
        guard (0.12...0.80).contains(metrics.coverageFraction) else {
            throw MindEyeProjectionError.invalidCapture("mask coverage \(metrics.coverageFraction) is outside 12...80%")
        }
        guard metrics.boundingBox.count == 4, metrics.centerErrorPixels.count == 2,
              abs(metrics.centerErrorPixels[0]) <= Double(width) * 0.02,
              abs(metrics.centerErrorPixels[1]) <= Double(height) * 0.02,
              !metrics.touchesEdge else {
            throw MindEyeProjectionError.invalidCapture(
                "mask framing is invalid: bounds=\(metrics.boundingBox) " +
                "centerError=\(metrics.centerErrorPixels) " +
                "touchesEdge=\(metrics.touchesEdge)"
            )
        }
    }
}
