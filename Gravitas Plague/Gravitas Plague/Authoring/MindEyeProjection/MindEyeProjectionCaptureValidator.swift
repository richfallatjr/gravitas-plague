#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation
import ImageIO

nonisolated enum MindEyeProjectionCaptureValidator {
    static func validate(directory: URL, manifest: MindEyeProjectionCaptureManifest) throws {
        guard manifest.captureID == "angel_head_v1",
              manifest.sourceWidth == 1_728, manifest.sourceHeight == 1_728,
              manifest.viewportWidth == 1_440, manifest.viewportHeight == 1_440,
              manifest.animationAdvancedFrames == 0, manifest.mediaTimeSeconds == 0 else {
            throw MindEyeProjectionError.invalidCapture("manifest identity or frame-zero state is invalid")
        }
        for output in manifest.outputs {
            let url = directory.appendingPathComponent(output.filename)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty, data.count == output.byteCount,
                  MindEyeProjectionExportStore.sha256(data) == output.SHA256 else {
                throw MindEyeProjectionError.invalidCapture("invalid output \(output.filename)")
            }
            if output.filename.hasSuffix(".png") {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      (properties[kCGImagePropertyPixelWidth] as? Int) == output.width,
                      (properties[kCGImagePropertyPixelHeight] as? Int) == output.height else {
                    throw MindEyeProjectionError.invalidCapture("invalid image output \(output.filename)")
                }
            } else if output.width != 0 || output.height != 0 {
                throw MindEyeProjectionError.invalidCapture("non-image output has image dimensions")
            }
        }
        let geometryDirectory = directory.appendingPathComponent(
            "GeometryPoses",
            isDirectory: true
        )
        let beautyNames = [
            "angel_head_v1_geometry-rest_000.png",
            "angel_head_v1_geometry-small_033.png",
            "angel_head_v1_geometry-round_050.png",
            "angel_head_v1_geometry-wide_100.png",
        ]
        let coverageNames = [
            "angel_head_v1_coverage-rest_000.png",
            "angel_head_v1_coverage-small_033.png",
            "angel_head_v1_coverage-round_050.png",
            "angel_head_v1_coverage-wide_100.png",
        ]
        let beautyHashes = try Set(beautyNames.map {
            try MindEyeProjectionExportStore.sha256(
                file: geometryDirectory.appendingPathComponent($0)
            )
        })
        let coverageHashes = try Set(coverageNames.map {
            try MindEyeProjectionExportStore.sha256(
                file: geometryDirectory.appendingPathComponent($0)
            )
        })
        guard beautyHashes.count == 4, coverageHashes.count >= 2 else {
            throw MindEyeProjectionError.invalidCapture(
                "blendshape pose captures do not contain distinct deformation states"
            )
        }
        try MindEyeProjectionValidation.validateAuthoredMaskForLockedCrop(.init(
            coverageFraction: manifest.maskCoverageFraction,
            boundingBox: manifest.maskBoundingBoxPixels,
            centerErrorPixels: manifest.maskCenterErrorPixels,
            touchesEdge: false
        ))
    }
}
#endif
