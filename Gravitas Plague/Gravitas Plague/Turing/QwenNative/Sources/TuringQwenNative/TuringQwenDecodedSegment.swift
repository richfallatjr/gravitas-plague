import Foundation

public struct TuringQwenDecodedSegment: Sendable {
    public let runID: String
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let voiceID: String
    public let audio: TuringQwenNativeAudio
    public let renderMetrics: TuringQwenRenderPhaseMetrics
    public let decodeSeconds: TimeInterval

    public init(
        runID: String,
        instanceID: TuringQwenNativeFreshInstanceID,
        segmentIndex: Int,
        voiceID: String,
        audio: TuringQwenNativeAudio,
        renderMetrics: TuringQwenRenderPhaseMetrics,
        decodeSeconds: TimeInterval
    ) {
        self.runID = runID
        self.instanceID = instanceID
        self.segmentIndex = segmentIndex
        self.voiceID = voiceID
        self.audio = audio
        self.renderMetrics = renderMetrics
        self.decodeSeconds = decodeSeconds
    }
}
