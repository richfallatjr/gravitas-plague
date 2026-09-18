import Foundation

public struct TuringQwenDecodedSegment: Sendable {
    public let runID: String
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let voiceID: String
    public let audio: TuringQwenNativeAudio
    public let renderMetrics: TuringQwenRenderPhaseMetrics
    public let decodeSeconds: TimeInterval
    public let recoveryGeneration: TuringQwenNativeRecoveryGeneration
    public let generatedRowCount: Int?
    public let conditioningReferenceRowCount: Int?
    public let decodeReferenceRowCount: Int?
    public let reachedEOS: Bool?

    public init(
        runID: String,
        instanceID: TuringQwenNativeFreshInstanceID,
        segmentIndex: Int,
        voiceID: String,
        audio: TuringQwenNativeAudio,
        renderMetrics: TuringQwenRenderPhaseMetrics,
        decodeSeconds: TimeInterval,
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial,
        generatedRowCount: Int? = nil,
        conditioningReferenceRowCount: Int? = nil,
        decodeReferenceRowCount: Int? = nil,
        reachedEOS: Bool? = nil
    ) {
        self.runID = runID
        self.instanceID = instanceID
        self.segmentIndex = segmentIndex
        self.voiceID = voiceID
        self.audio = audio
        self.renderMetrics = renderMetrics
        self.decodeSeconds = decodeSeconds
        self.recoveryGeneration = recoveryGeneration
        self.generatedRowCount = generatedRowCount
        self.conditioningReferenceRowCount = conditioningReferenceRowCount
        self.decodeReferenceRowCount = decodeReferenceRowCount
        self.reachedEOS = reachedEOS
    }
}
