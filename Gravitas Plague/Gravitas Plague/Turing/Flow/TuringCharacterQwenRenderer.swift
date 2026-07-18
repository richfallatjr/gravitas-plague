import Foundation

struct TuringCharacterRenderReport:
  Sendable,
  Equatable
{
  let expectedSegmentCount: Int
  let successfulSegmentIndices: Set<Int>
  let skippedSegmentReasons: [Int: String]

  var skippedSegmentIndices: Set<Int> {
    Set(skippedSegmentReasons.keys)
  }

  var isCompleteSuccess: Bool {
    successfulSegmentIndices.count == expectedSegmentCount && skippedSegmentReasons.isEmpty
  }
}

protocol TuringCharacterRendering:
  Sendable
{
  func render(
    segments: [TuringSpeechSegment],
    runID: String,
    onStarted:
      @Sendable @escaping (Int) async -> Void,
    onFinished:
      @Sendable @escaping (
        Int,
        TuringComputeGapGeneratedAudio
      ) async -> Void,
    onSkipped:
      @Sendable @escaping (
        Int,
        String
      ) async -> Void
  ) async throws
    -> TuringCharacterRenderReport
}

protocol TuringCharacterRendererMaking:
  Sendable
{
  func make(
    runtime:
      TuringCharacterRuntimeDefinition
  ) -> any TuringCharacterRendering
}

struct TuringCharacterQwenRendererFactory:
  TuringCharacterRendererMaking,
  Sendable
{
  func make(
    runtime:
      TuringCharacterRuntimeDefinition
  ) -> any TuringCharacterRendering {
    TuringCharacterQwenRenderer(
      runtime: runtime
    )
  }
}

actor TuringCharacterQwenRenderer:
  TuringCharacterRendering
{
  typealias StartedCallback =
    @Sendable (Int) async -> Void

  typealias FinishedCallback =
    @Sendable (
      Int,
      TuringComputeGapGeneratedAudio
    ) async -> Void

  typealias SkippedCallback =
    @Sendable (
      Int,
      String
    ) async -> Void

  private let runtime: TuringCharacterRuntimeDefinition
  private let resources: TuringBaseCloneRuntimeResources
  private let arbiter: TuringQwenCharacterPoolArbiter

  init(
    runtime:
      TuringCharacterRuntimeDefinition,
    resources:
      TuringBaseCloneRuntimeResources =
      TuringBaseCloneRuntimeResources(),
    arbiter:
      TuringQwenCharacterPoolArbiter =
      .shared
  ) {
    self.runtime = runtime
    self.resources = resources
    self.arbiter = arbiter
  }

  func render(
    segments: [TuringSpeechSegment],
    runID: String,
    onStarted:
      @escaping StartedCallback,
    onFinished:
      @escaping FinishedCallback,
    onSkipped:
      @escaping SkippedCallback
  ) async throws
    -> TuringCharacterRenderReport
  {
    guard segments.isEmpty == false else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(runtime.characterID) Qwen render requires at least one segment."
        )
    }

    let session = TuringCharacterQwenRenderSession(
      runtime: runtime,
      runID: runID,
      resources: resources,
      arbiter: arbiter
    )
    do {
      try await session.begin()
      let result = try await session.renderStage(
        TuringCommittedSpeechStage(
          stageID: "legacy",
          kind: .promptVoice,
          globalRange: 0..<segments.count,
          segments: segments
        ),
        onStarted: onStarted,
        onFinished: onFinished,
        onSkipped: onSkipped
      )
      await session.finish(reason: "legacyRenderFinished")
      return result
    } catch {
      await session.cancel(reason: error.localizedDescription)
      throw error
    }
  }
}
