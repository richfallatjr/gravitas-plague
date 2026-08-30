import Foundation

nonisolated struct Chapter03AngelPerformanceSample: Sendable, Equatable {
    let runID: UUID
    let playbackID: UUID
    let frameIndex: Int
    let pose: MindEyeMouthPose
    let jawTargetWeight: Float
    let emberBirthRateMultiplier: Float
    let reachedTrackEnd: Bool
}

@MainActor
protocol Chapter03AngelProjectionPoseReceiving: AnyObject {
    func setAngelMouthPose(_ pose: MindEyeMouthPose)
}
