import Foundation

@MainActor
protocol TuringGeneratedAudioPlaybackSink: AnyObject {
  func qwenComputeStarted(segmentIndex: Int) async

  func qwenComputeFinished(
    segmentIndex: Int,
    audio: TuringComputeGapGeneratedAudio
  ) async

  func qwenComputeSkipped(
    segmentIndex: Int,
    reason: String
  ) async

  func qwenComputeAllFinished() async
}

extension TuringStoryWalkiePlaybackCoordinator:
  TuringGeneratedAudioPlaybackSink
{
}
