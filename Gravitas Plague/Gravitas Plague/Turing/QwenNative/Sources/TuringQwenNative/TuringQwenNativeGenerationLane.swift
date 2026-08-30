import Foundation

public struct TuringQwenNativeBaseCloneSegmentRequest:
  Sendable
{
  public let segmentIndex: Int
  public let text: String
  public let language: String
  public let cloneProfile: TuringQwenNativeCloneProfile
  public let maxNewRows: Int
  public let performanceMode: TuringQwenNativePerformanceMode
  public let referenceRowLimit: Int?
  public let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy

  public let samplingPolicy: TuringQwenNativeSamplingPolicy
  public let samplingSeed: UInt64
  public let generationQualityPolicy: TuringQwenNativeGenerationQualityPolicy

  public init(
    segmentIndex: Int,
    text: String,
    language: String,
    cloneProfile:
      TuringQwenNativeCloneProfile,
    maxNewRows: Int,
    performanceMode:
      TuringQwenNativePerformanceMode,
    referenceRowLimit: Int?,
    referenceWindowStrategy:
      TuringQwenNativeReferenceWindowStrategy,
    samplingPolicy:
      TuringQwenNativeSamplingPolicy =
      .greedy,
    samplingSeed: UInt64 =
      0x9E37_79B9_7F4A_7C15,
    generationQualityPolicy:
      TuringQwenNativeGenerationQualityPolicy =
      .permissive
  ) {
    self.segmentIndex = segmentIndex
    self.text = text
    self.language = language
    self.cloneProfile = cloneProfile
    self.maxNewRows = maxNewRows
    self.performanceMode =
      performanceMode
    self.referenceRowLimit =
      referenceRowLimit
    self.referenceWindowStrategy =
      referenceWindowStrategy
    self.samplingPolicy =
      samplingPolicy
    self.samplingSeed =
      samplingSeed
    self.generationQualityPolicy =
      generationQualityPolicy
  }
}

public struct TuringQwenNativeGeneratedAudio:
  Sendable
{
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
    streamMode:
      TuringQwenNativeLaneStreamMode
  ) {
    self.laneID = laneID
    self.segmentIndex = segmentIndex
    self.audio = audio
    self.renderSeconds = renderSeconds
    self.streamMode = streamMode
  }
}

@available(
  *,
  deprecated,
  message: "Production Turing uses Fresh2 with explicit residency ownership."
)
public actor TuringQwenNativeGenerationLane {
  public let laneID: Int
  public let stream: TuringQwenNativeLaneStream

  private let residentResources: TuringQwenNativeResidentResources
  private let engine: TuringQwenNativeBaseCloneEngine

  public init(
    laneID: Int,
    residentResources:
      TuringQwenNativeResidentResources
  ) throws {
    self.laneID = laneID
    self.residentResources =
      residentResources
    stream =
      TuringQwenNativeLaneStream(
        laneID: laneID
      )
    engine =
      try TuringQwenNativeBaseCloneEngine(
        modelRoot:
          residentResources.modelRoot,
        ownedResidentResources:
          residentResources,
        trace:
          .stdout(
            prefix:
              "[TuringQwenParallel.lane\(laneID)]"
          )
      )
  }

  public func renderSegment(
    _ request:
      TuringQwenNativeBaseCloneSegmentRequest
  ) async throws
    -> TuringQwenNativeGeneratedAudio
  {
    let renderStart = Date()

    print(
      """
      [TuringQwenParallel] lane started
        laneID: \(laneID)
        segmentIndex: \(request.segmentIndex)
        sharedWeights: true
        streamMode: \(stream.mode.rawValue)
      """)

    let prompt =
      TuringQwenNativeBaseClonePrompt(
        text: request.text,
        language: request.language,
        cloneProfile:
          request.cloneProfile,
        maxNewRows:
          request.maxNewRows,
        performanceMode:
          request.performanceMode,
        referenceRowLimit:
          request.referenceRowLimit,
        referenceWindowStrategy:
          request
          .referenceWindowStrategy,
        samplingPolicy:
          request.samplingPolicy,
        samplingSeed:
          request.samplingSeed,
        generationQualityPolicy:
          request
          .generationQualityPolicy
      )

    let audio =
      try await engine
      .generateBaseClone(
        prompt: prompt
      )
    let renderSeconds =
      Date().timeIntervalSince(
        renderStart
      )

    print(
      """
      [TuringQwenParallel] lane finished
        laneID: \(laneID)
        segmentIndex: \(request.segmentIndex)
        audioDurationSeconds: \(String(format: "%.3f", audio.durationSeconds))
        renderSeconds: \(String(format: "%.3f", renderSeconds))
        sharedWeights: true
      """)

    return TuringQwenNativeGeneratedAudio(
      laneID: laneID,
      segmentIndex:
        request.segmentIndex,
      audio: audio,
      renderSeconds:
        renderSeconds,
      streamMode: stream.mode
    )
  }

  public func releaseResidentState(
    reason: String
  ) async {
    await engine.releaseResidentState(
      reason:
        "lane\(laneID).\(reason)",
      logMemorySnapshot: false
    )
  }
}
