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

    /// The artist-authored Angel mask is intentionally asymmetric within the
    /// owner-authored framing cube. For that path, the cube locks the camera and
    /// the hard safety requirement is that every projected pixel survives the
    /// exact 1728 -> 1440 crop without touching an edge. Re-centering the camera
    /// from the mask would break the cube contract and plate registration.
    static func validateAuthoredMaskForLockedCrop(
        _ metrics: MaskMetrics,
        cropOriginX: Int = 144,
        cropOriginY: Int = 144,
        cropWidth: Int = 1_440,
        cropHeight: Int = 1_440
    ) throws {
        guard (0.12...0.80).contains(metrics.coverageFraction) else {
            throw MindEyeProjectionError.invalidCapture(
                "authored mask coverage \(metrics.coverageFraction) is outside 12...80%"
            )
        }
        guard metrics.boundingBox.count == 4,
              metrics.centerErrorPixels.count == 2 else {
            throw MindEyeProjectionError.invalidCapture(
                "authored mask metrics are incomplete"
            )
        }
        let minimumX = metrics.boundingBox[0]
        let minimumY = metrics.boundingBox[1]
        let maximumX = minimumX + metrics.boundingBox[2] - 1
        let maximumY = minimumY + metrics.boundingBox[3] - 1
        guard minimumX >= cropOriginX,
              minimumY >= cropOriginY,
              maximumX < cropOriginX + cropWidth,
              maximumY < cropOriginY + cropHeight,
              !metrics.touchesEdge else {
            throw MindEyeProjectionError.invalidCapture(
                "authored mask escapes locked crop: bounds=\(metrics.boundingBox) " +
                "crop=[\(cropOriginX), \(cropOriginY), \(cropWidth), \(cropHeight)] " +
                "touchesEdge=\(metrics.touchesEdge)"
            )
        }
    }
}
