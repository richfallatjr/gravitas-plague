import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringRichGlobalPlaybackCoordinatorTests: XCTestCase {
  func testScriptPoint02OrderIsOpenRichPRGeneratedThenSend() async throws {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let openURL = URL(fileURLWithPath: "/tmp/open-comm.wav")
    let sendURL = URL(fileURLWithPath: "/tmp/send-comm.wav")
    let richPRURL = URL(
      fileURLWithPath: "/tmp/pr-rich-script-point-02.mp3"
    )
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )

    var policy = TuringRichGlobalPlaybackCoordinator.Policy()
    policy.deadAirAfterFillerEnabled = false

    let coordinator = TuringRichGlobalPlaybackCoordinator(
      policy: policy,
      player: fakePlayer,
      fillerCatalog: TuringRichFillerCatalog(
        weightedEntries: []
      ),
      transmissionProvider: FakeRichTransmissionProvider(
        envelope: TuringRichWalkieTransmissionEnvelope(
          openURL: openURL,
          sendURL: sendURL
        )
      ),
      rootURL: tempRoot
    )

    try await coordinator.beginRun(
      runID: "test.scriptPoint02",
      outputContext: .walkieOutgoingGlobal,
      expectedSegmentCount: 2,
      playbackInitiallyBlocked: false,
      expectsPrerecording: true
    )
    try await coordinator.enqueuePrerecording(
      id: "prologue.walkie.rich.scriptPoint02.001",
      fileURL: richPRURL
    )

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.walkieOpen]
    )

    // Qwen finishes out of order while the authored Rich transmission
    // is still in progress.
    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeStarted(segmentIndex: 1)
    await coordinator.qwenComputeFinished(
      segmentIndex: 1,
      audio: generatedAudio(index: 1)
    )
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeAllFinished()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.walkieOpen]
    )

    fakePlayer.completeActive()
    await settle()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [
        .walkieOpen,
        .prerecording,
      ]
    )
    XCTAssertEqual(
      fakePlayer.startedClips.last?.fileURL,
      richPRURL
    )

    fakePlayer.completeActive()
    await settle()

    // The PR is the initial buffer. Because segment zero is ready, no
    // filler is inserted between the Rich PR and generated continuation.
    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [
        .walkieOpen,
        .prerecording,
        .generated,
      ]
    )
    XCTAssertEqual(
      fakePlayer.startedClips.last?.label,
      "segment_0000"
    )

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(
      fakePlayer.startedClips.last?.label,
      "segment_0001"
    )

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(
      fakePlayer.startedClips.last?.kind,
      .walkieSend
    )

    fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()
    try await coordinator.throwIfFailed()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [
        .walkieOpen,
        .prerecording,
        .generated,
        .generated,
        .walkieSend,
      ]
    )
  }

  func testExpectedRichPRBlocksGeneratedUntilActualPRCompletion() async throws {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let richPRURL = URL(
      fileURLWithPath: "/tmp/pr-rich-script-point-02.mp3"
    )
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )

    var policy = TuringRichGlobalPlaybackCoordinator.Policy()
    policy.firstSegmentPrerollFillerCount = 0
    policy.deadAirAfterFillerEnabled = false

    let coordinator = TuringRichGlobalPlaybackCoordinator(
      policy: policy,
      player: fakePlayer,
      fillerCatalog: TuringRichFillerCatalog(
        weightedEntries: []
      ),
      rootURL: tempRoot
    )

    try await coordinator.beginRun(
      runID: "test.richPRGate",
      outputContext: .roomGlobal,
      expectedSegmentCount: 1,
      expectsPrerecording: true
    )
    try await coordinator.enqueuePrerecording(
      id: "richPR",
      fileURL: richPRURL
    )

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.prerecording]
    )

    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeAllFinished()
    await settle()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.prerecording]
    )

    fakePlayer.completeActive()
    await settle()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [
        .prerecording,
        .generated,
      ]
    )

    fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()
    try await coordinator.throwIfFailed()
  }

  func testRoomGlobalWithoutPRDoesNotPlayWalkieEnvelope() async throws {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )
    var policy = TuringRichGlobalPlaybackCoordinator.Policy()
    policy.firstSegmentPrerollFillerCount = 0
    policy.deadAirAfterFillerEnabled = false

    let coordinator = TuringRichGlobalPlaybackCoordinator(
      policy: policy,
      player: fakePlayer,
      fillerCatalog: TuringRichFillerCatalog(
        weightedEntries: []
      ),
      transmissionProvider: FakeRichTransmissionProvider(
        envelope: TuringRichWalkieTransmissionEnvelope(
          openURL: URL(fileURLWithPath: "/tmp/open.wav"),
          sendURL: URL(fileURLWithPath: "/tmp/send.wav")
        )
      ),
      rootURL: tempRoot
    )

    try await coordinator.beginRun(
      runID: "test.rich.room",
      outputContext: .roomGlobal,
      expectedSegmentCount: 1
    )
    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeAllFinished()
    await settle()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.generated]
    )

    fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()
    try await coordinator.throwIfFailed()

    XCTAssertFalse(
      fakePlayer.startedClips.contains {
        $0.kind == .walkieOpen || $0.kind == .walkieSend
      }
    )
  }

  func testFailedGeneratedCompletionDoesNotAdvance() async throws {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )
    var policy = TuringRichGlobalPlaybackCoordinator.Policy()
    policy.firstSegmentPrerollFillerCount = 0
    policy.deadAirAfterFillerEnabled = false

    let coordinator = TuringRichGlobalPlaybackCoordinator(
      policy: policy,
      player: fakePlayer,
      fillerCatalog: TuringRichFillerCatalog(
        weightedEntries: []
      ),
      rootURL: tempRoot
    )

    try await coordinator.beginRun(
      runID: "test.rich.failure",
      outputContext: .roomGlobal,
      expectedSegmentCount: 2
    )
    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeStarted(segmentIndex: 1)
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeFinished(
      segmentIndex: 1,
      audio: generatedAudio(index: 1)
    )
    await coordinator.qwenComputeAllFinished()
    await settle()

    XCTAssertEqual(
      fakePlayer.startedClips.last?.label,
      "segment_0000"
    )

    fakePlayer.completeActive(successfully: false)
    await coordinator.waitUntilPlaybackFinished()

    XCTAssertThrowsError(
      try coordinator.throwIfFailed()
    )
    XCTAssertFalse(
      fakePlayer.startedClips.contains {
        $0.label == "segment_0001"
      }
    )
  }

  private func generatedAudio(
    index: Int
  ) -> TuringComputeGapGeneratedAudio {
    let samples = (0..<2_400).map { sampleIndex in
      Float(
        sin(Double(sampleIndex) * 0.02)
      ) * 0.1
    }
    return TuringComputeGapGeneratedAudio(
      segmentIndex: index,
      samples: samples,
      sampleRate: 24_000,
      channelCount: 1
    )
  }

  private func settle() async {
    for _ in 0..<8 {
      await Task.yield()
    }
  }
}
