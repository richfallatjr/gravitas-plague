import Foundation

actor TuringRichQwenRenderer {
  private let renderer = TuringBaseCloneCharacterRenderer(
    character: .rich
  )

  func render(
    segments: [TuringSpeechSegment],
    runID: String,
    onStarted: @Sendable @escaping (Int) async -> Void,
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
  ) async throws {
    try await renderer.render(
      segments: segments,
      runID: runID,
      onStarted: onStarted,
      onFinished: onFinished,
      onSkipped: onSkipped
    )
  }
}
