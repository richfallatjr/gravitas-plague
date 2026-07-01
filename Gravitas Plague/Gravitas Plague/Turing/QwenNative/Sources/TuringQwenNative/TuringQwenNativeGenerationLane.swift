import Foundation

public struct TuringQwenNativeBaseCloneSegmentRequest: Sendable {
    public let segmentIndex: Int
    public let text: String
    public let language: String
    public let cloneProfile: TuringQwenNativeCloneProfile
    public let maxNewRows: Int
    public let performanceMode: TuringQwenNativePerformanceMode
    public let referenceRowLimit: Int?
    public let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy

    public init(
        segmentIndex: Int,
        text: String,
        language: String,
        cloneProfile: TuringQwenNativeCloneProfile,
        maxNewRows: Int,
        performanceMode: TuringQwenNativePerformanceMode,
        referenceRowLimit: Int?,
        referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy
    ) {
        self.segmentIndex = segmentIndex
        self.text = text
        self.language = language
        self.cloneProfile = cloneProfile
        self.maxNewRows = maxNewRows
        self.performanceMode = performanceMode
        self.referenceRowLimit = referenceRowLimit
        self.referenceWindowStrategy = referenceWindowStrategy
    }
}

public struct TuringQwenNativeGeneratedAudio: Sendable {
    public let laneID: Int
    public let segmentIndex: Int
    public let audio: TuringQwenNativeAudio
    public let renderSeconds: Double
    public let streamMode: TuringQwenNativeLaneStreamMode

    public init(
        laneID: Int,
        segmentIndex: Int,
        audio: TuringQwenNativeAudio,
        renderSeconds: Double,
        streamMode: TuringQwenNativeLaneStreamMode
    ) {
        self.laneID = laneID
        self.segmentIndex = segmentIndex
        self.audio = audio
        self.renderSeconds = renderSeconds
        self.streamMode = streamMode
    }
}

public actor TuringQwenNativeGenerationLane {
    public let laneID: Int
    public let stream: TuringQwenNativeLaneStream
    private let residentResources: TuringQwenNativeResidentResources
    private let engine: TuringQwenNativeBaseCloneEngine

    public init(
        laneID: Int,
        residentResources: TuringQwenNativeResidentResources
    ) throws {
        self.laneID = laneID
        self.residentResources = residentResources
        self.stream = TuringQwenNativeLaneStream(laneID: laneID)
        self.engine = try TuringQwenNativeBaseCloneEngine(
            modelRoot: residentResources.modelRoot,
            residentResources: residentResources,
            trace: .stdout(prefix: "[TuringQwenParallel.lane\(laneID)]")
        )
    }

    public func renderSegment(
        _ request: TuringQwenNativeBaseCloneSegmentRequest
    ) async throws -> TuringQwenNativeGeneratedAudio {
        let renderStart = Date()
        print("""
        [TuringQwenParallel] lane started
          laneID: \(laneID)
          segmentIndex: \(request.segmentIndex)
          sharedWeights: true
          streamMode: \(stream.mode.rawValue)
        """)
        let prompt = TuringQwenNativeBaseClonePrompt(
            text: request.text,
            language: request.language,
            cloneProfile: request.cloneProfile,
            maxNewRows: request.maxNewRows,
            performanceMode: request.performanceMode,
            referenceRowLimit: request.referenceRowLimit,
            referenceWindowStrategy: request.referenceWindowStrategy
        )
        let audio = try await engine.generateBaseClone(prompt: prompt)
        let renderSeconds = Date().timeIntervalSince(renderStart)
        print("""
        [TuringQwenParallel] lane finished
          laneID: \(laneID)
          segmentIndex: \(request.segmentIndex)
          audioDurationSeconds: \(String(format: "%.3f", audio.durationSeconds))
          renderSeconds: \(String(format: "%.3f", renderSeconds))
          sharedWeights: true
        """)
        return TuringQwenNativeGeneratedAudio(
            laneID: laneID,
            segmentIndex: request.segmentIndex,
            audio: audio,
            renderSeconds: renderSeconds,
            streamMode: stream.mode
        )
    }

    public func releaseResidentState(
        reason: String
    ) async {
        await engine.releaseResidentState(
            reason: "lane\(laneID).\(reason)",
            logMemorySnapshot: false
        )
    }
}
