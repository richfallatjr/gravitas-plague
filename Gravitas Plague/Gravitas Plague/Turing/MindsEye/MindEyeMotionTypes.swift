import Foundation

nonisolated struct MindEyeMotionRenderSample: Sendable, Equatable {
    let backgroundTransform: MindEyeLayerTransform
    let characterTransform: MindEyeLayerTransform
    let eyeSelection: MindEyeEyeSelection
    let simulationTimeSeconds: Double
    let motionUpdateIndex: UInt64
    let blinkCount: UInt64
    let gripCorrectionCount: UInt64

    static let resting = MindEyeMotionRenderSample(
        backgroundTransform: .identity,
        characterTransform: .identity,
        eyeSelection: .open(variantIndex: 0),
        simulationTimeSeconds: 0,
        motionUpdateIndex: 0,
        blinkCount: 0,
        gripCorrectionCount: 0
    )
}

@MainActor
protocol MindEyeMotionFrameSink: AnyObject {
    func receiveMindEyeMotionSample(_ sample: MindEyeMotionRenderSample)
    func receiveMindEyeMotionFailure(_ failure: MindEyeFailure)
}
