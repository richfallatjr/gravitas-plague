import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringDeferredBigMikePlaybackBridgeTests:
  XCTestCase
{

  func testEventsBufferThenFlushInSubmissionOrder()
    async
  {
    let bridge =
      TuringDeferredBigMikePlaybackBridge()
    let sink =
      FakeGeneratedAudioPlaybackSink()

    await bridge.qwenComputeStarted(
      segmentIndex: 1
    )
    await bridge.qwenComputeFinished(
      segmentIndex: 1,
      audio:
        TuringComputeGapGeneratedAudio(
          segmentIndex: 1,
          samples: [0.1, 0.2],
          sampleRate: 24_000
        )
    )
    await bridge.qwenComputeStarted(
      segmentIndex: 0
    )
    await bridge.qwenComputeFinished(
      segmentIndex: 0,
      audio:
        TuringComputeGapGeneratedAudio(
          segmentIndex: 0,
          samples: [0.3],
          sampleRate: 24_000
        )
    )
    await bridge.qwenComputeAllFinished()

    XCTAssertTrue(sink.events.isEmpty)

    await bridge.attach(to: sink)

    XCTAssertEqual(
      sink.events,
      [
        "started:1",
        "finished:1:2",
        "started:0",
        "finished:0:1",
        "allFinished",
      ]
    )
  }

  func testEventsForwardImmediatelyAfterAttach()
    async
  {
    let bridge =
      TuringDeferredBigMikePlaybackBridge()
    let sink =
      FakeGeneratedAudioPlaybackSink()

    await bridge.attach(to: sink)
    await bridge.qwenComputeSkipped(
      segmentIndex: 2,
      reason: "test"
    )

    XCTAssertEqual(
      sink.events,
      ["skipped:2:test"]
    )
  }

  func testCancelDropsBufferedAndFutureEvents()
    async
  {
    let bridge =
      TuringDeferredBigMikePlaybackBridge()
    let sink =
      FakeGeneratedAudioPlaybackSink()

    await bridge.qwenComputeStarted(
      segmentIndex: 0
    )
    bridge.cancel(reason: "test")
    await bridge.attach(to: sink)
    await bridge.qwenComputeAllFinished()

    XCTAssertTrue(sink.events.isEmpty)
  }
}
