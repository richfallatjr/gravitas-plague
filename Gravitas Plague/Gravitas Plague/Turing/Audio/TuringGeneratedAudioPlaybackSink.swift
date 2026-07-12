import Foundation

@MainActor
protocol TuringGeneratedAudioPlaybackSink: AnyObject {
  func setExpectedGeneratedSegmentCount(_ count: Int) async

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

extension TuringGeneratedAudioPlaybackSink {
  func setExpectedGeneratedSegmentCount(_ count: Int) async {}
}

extension TuringStoryWalkiePlaybackCoordinator:
  TuringGeneratedAudioPlaybackSink
{
}
