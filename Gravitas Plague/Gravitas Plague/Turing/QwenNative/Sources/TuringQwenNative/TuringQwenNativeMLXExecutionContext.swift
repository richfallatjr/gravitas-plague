import Foundation
import MLX

public enum TuringQwenNativeMLXPhase: String, Sendable, Equatable, Codable {
    case warmLoad
    case initialTalker
    case dynamicTalker
    case codePredictor
    case CPUCodebookMaterialization
    case speechDecoder
    case cacheClear
    case unload
    case other
}

public struct TuringQwenNativeMLXExecutionContext: Sendable, Equatable {
    public let runID: String
    public let instanceID: TuringQwenNativeFreshInstanceID?
    public let segmentIndex: Int?
    public let laneIndex: Int?
    public let decodeID: Int?
    public let phase: TuringQwenNativeMLXPhase
    public let stage: String?
    public let rowRange: Range<Int>?
    public let talkerPositionRange: Range<Int>?
    public let appMetalInFlightCount: Int
    public let mindEyeCompositorInFlightCount: Int

    public init(
        runID: String,
        instanceID: TuringQwenNativeFreshInstanceID? = nil,
        segmentIndex: Int? = nil,
        laneIndex: Int? = nil,
        decodeID: Int? = nil,
        phase: TuringQwenNativeMLXPhase,
        stage: String? = nil,
        rowRange: Range<Int>? = nil,
        talkerPositionRange: Range<Int>? = nil,
        appMetalInFlightCount: Int = 0,
        mindEyeCompositorInFlightCount: Int = 0
    ) {
        self.runID = runID
        self.instanceID = instanceID
        self.segmentIndex = segmentIndex
        self.laneIndex = laneIndex
        self.decodeID = decodeID
        self.phase = phase
        self.stage = stage
        self.rowRange = rowRange
        self.talkerPositionRange = talkerPositionRange
        self.appMetalInFlightCount = appMetalInFlightCount
        self.mindEyeCompositorInFlightCount = mindEyeCompositorInFlightCount
    }

    var metalContext: TuringMetalExecutionContext {
        TuringMetalExecutionContext(
            runID: runID,
            instanceID: instanceID?.rawValue,
            segmentIndex: segmentIndex,
            laneIndex: laneIndex,
            decodeID: decodeID,
            phase: phase.rawValue,
            stage: stage,
            rowRange: rowRange,
            talkerPositionRange: talkerPositionRange,
            appMetalInFlightCount: appMetalInFlightCount,
            mindEyeCompositorInFlightCount: mindEyeCompositorInFlightCount
        )
    }
}
