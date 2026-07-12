import Foundation

@MainActor
final class TuringDeferredBigMikePlaybackBridge {
  private enum Event {
    case expectedSegmentCount(Int)
    case started(Int)
    case finished(
      Int,
      TuringComputeGapGeneratedAudio
    )
    case skipped(
      Int,
      String
    )
    case allFinished
  }

  private var target: (any TuringGeneratedAudioPlaybackSink)?
  private var bufferedEvents: [Event] = []
  private var cancelled = false

  func setExpectedGeneratedSegmentCount(
    _ count: Int
  ) async {
    await submit(.expectedSegmentCount(count))
  }

  func qwenComputeStarted(
    segmentIndex: Int
  ) async {
    await submit(.started(segmentIndex))
  }

  func qwenComputeFinished(
    segmentIndex: Int,
    audio: TuringComputeGapGeneratedAudio
  ) async {
    await submit(
      .finished(
        segmentIndex,
        audio
      )
    )
  }

  func qwenComputeSkipped(
    segmentIndex: Int,
    reason: String
  ) async {
    await submit(
      .skipped(
        segmentIndex,
        reason
      )
    )
  }

  func qwenComputeAllFinished() async {
    await submit(.allFinished)
  }

  func attach(
    to target: any TuringGeneratedAudioPlaybackSink
  ) async {
    guard cancelled == false else {
      return
    }

    self.target = target
    let events = bufferedEvents
    bufferedEvents.removeAll(
      keepingCapacity: false
    )

    print(
      """
      [TuringDeferredBigMike] playback sink attached
        bufferedEventCount: \(events.count)
      """)

    for event in events {
      await forward(
        event,
        to: target
      )
    }
  }

  func cancel(reason: String) {
    cancelled = true
    target = nil
    bufferedEvents.removeAll(
      keepingCapacity: false
    )

    print(
      """
      [TuringDeferredBigMike] cancelled
        reason: \(reason)
      """)
  }

  private func submit(
    _ event: Event
  ) async {
    guard cancelled == false else {
      return
    }

    if let target {
      await forward(
        event,
        to: target
      )
    } else {
      bufferedEvents.append(event)

      print(
        """
        [TuringDeferredBigMike] event buffered
          bufferedEventCount: \(bufferedEvents.count)
          playbackSinkAttached: false
        """)
    }
  }

  private func forward(
    _ event: Event,
    to target: any TuringGeneratedAudioPlaybackSink
  ) async {
    switch event {
    case .expectedSegmentCount(let count):
      await target.setExpectedGeneratedSegmentCount(count)

    case .started(let index):
      await target.qwenComputeStarted(
        segmentIndex: index
      )

    case .finished(
      let index,
      let audio
    ):
      await target.qwenComputeFinished(
        segmentIndex: index,
        audio: audio
      )

    case .skipped(
      let index,
      let reason
    ):
      await target.qwenComputeSkipped(
        segmentIndex: index,
        reason: reason
      )

    case .allFinished:
      await target.qwenComputeAllFinished()
    }
  }
}
