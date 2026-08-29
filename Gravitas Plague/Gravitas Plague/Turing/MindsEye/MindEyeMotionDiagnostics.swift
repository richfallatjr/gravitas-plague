import Foundation
import OSLog

nonisolated struct MindEyeMotionSnapshot: Sendable, Equatable {
    let isInstalled: Bool
    let isPaused: Bool
    let rootSeed: UInt64?
    let simulationTimeSeconds: Double
    let motionUpdateIndex: UInt64
    let backgroundTransform: MindEyeLayerTransform
    let characterTransform: MindEyeLayerTransform
    let eyeSelection: MindEyeEyeSelection
    let blinkCount: UInt64
    let gripCorrectionCount: UInt64
    let compositorClampCount: UInt64
    let compositorCoalescedCount: UInt64
}

nonisolated enum MindEyeMotionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gravitas.plague",
        category: "MindEyeMotion"
    )

    static func start(vignetteID: String, seed: UInt64) {
        logger.debug(
            "MindEyeMotion.start vignette=\(vignetteID, privacy: .public) seed=\(seed, privacy: .public)"
        )
    }

    static func stop(
        vignetteID: String,
        reason: String,
        blinkCount: UInt64,
        gripCorrectionCount: UInt64
    ) {
        logger.debug(
            "MindEyeMotion.stop vignette=\(vignetteID, privacy: .public) reason=\(reason, privacy: .public) MindEyeMotion.blinkCount=\(blinkCount, privacy: .public) MindEyeMotion.gripCorrectionCount=\(gripCorrectionCount, privacy: .public)"
        )
    }

    static func pause(vignetteID: String) {
        logger.debug("MindEyeMotion.pause vignette=\(vignetteID, privacy: .public)")
    }

    static func resume(vignetteID: String) {
        logger.debug("MindEyeMotion.resume vignette=\(vignetteID, privacy: .public)")
    }

    static func failure(vignetteID: String, code: MindEyeFailureCode) {
        logger.error(
            "MindEyeMotion.failure vignette=\(vignetteID, privacy: .public) code=\(code.rawValue, privacy: .public)"
        )
    }

    static func traceQualification(label: String) {
        logger.debug("MindEyeMotion.traceQualification label=\(label, privacy: .public)")
    }
}
