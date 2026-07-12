import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringStoryWalkiePlaybackCoordinatorRichTests: XCTestCase {
  func testRichPRAndGeneratedSegmentsUseScriptPoint01CoordinatorInOrder()
    async throws
  {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fillerDirectory = try makeFillerDirectory(in: rootURL)
    var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
    policy.voiceRoute = .playerGlobal
    policy.outputProcessingPolicy = .rich
    policy.firstSegmentPrerollFillerCount = 1
    policy.chainFillerFromPrerecordingToFirstGenerated = true
    policy.deadAirAfterFillerEnabled = false
    policy.fillerDirectoryCandidates = [fillerDirectory.path]

    let coordinator = TuringStoryWalkiePlaybackCoordinator(
      policy: policy,
      rootURL: rootURL,
      globalPlayer: fakePlayer
    )

    await coordinator.beginRun(
      runID: "test.scriptPoint02.sharedOwner",
      expectedSegmentCount: nil
    )
    let prerecordingURL = URL(
      fileURLWithPath: "/tmp/pr-rich-script-point-02.mp3"
    )
    await coordinator.enqueuePrerecording(
      id: "prologue.walkie.rich.scriptPoint02.001",
      fileURL: prerecordingURL
    )

    XCTAssertEqual(fakePlayer.startedClips.map(\.kind), [.prerecording])

    await coordinator.setExpectedGeneratedSegmentCount(2)
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

    XCTAssertEqual(fakePlayer.startedClips.map(\.kind), [.prerecording])

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(fakePlayer.startedClips.last?.kind, .filler)

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(fakePlayer.startedClips.last?.label, "segment_0000")

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(fakePlayer.startedClips.last?.label, "segment_0001")

    fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.prerecording, .filler, .generated, .generated]
    )
    let completedCount = await coordinator.completedGeneratedSegmentCount()
    XCTAssertEqual(completedCount, 2)
  }

  func testRichPRChainsFillerUntilFirstGeneratedSegmentIsReady()
    async throws
  {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fillerDirectory = try makeFillerDirectory(in: rootURL)
    var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
    policy.voiceRoute = .playerGlobal
    policy.outputProcessingPolicy = .rich
    policy.firstSegmentPrerollFillerCount = 1
    policy.chainFillerFromPrerecordingToFirstGenerated = true
    policy.deadAirAfterFillerEnabled = true
    policy.fillerDirectoryCandidates = [fillerDirectory.path]

    let coordinator = TuringStoryWalkiePlaybackCoordinator(
      policy: policy,
      rootURL: rootURL,
      globalPlayer: fakePlayer
    )

    await coordinator.beginRun(
      runID: "test.scriptPoint02.continuousPRBridge",
      expectedSegmentCount: nil
    )
    await coordinator.enqueuePrerecording(
      id: "prologue.walkie.rich.scriptPoint02.001",
      fileURL: URL(fileURLWithPath: "/tmp/pr-rich-script-point-02.mp3")
    )

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(fakePlayer.startedClips.map(\.kind), [.prerecording, .filler])

    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.prerecording, .filler, .filler]
    )

    await coordinator.setExpectedGeneratedSegmentCount(1)
    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeAllFinished()

    XCTAssertEqual(fakePlayer.startedClips.last?.kind, .filler)
    fakePlayer.completeActive()
    await settle()
    XCTAssertEqual(fakePlayer.startedClips.last?.kind, .generated)

    fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()
    XCTAssertEqual(
      fakePlayer.startedClips.map(\.kind),
      [.prerecording, .filler, .filler, .generated]
    )
  }

  func testRichGenerationFailureDoesNotCancelActivePrerecording()
    async throws
  {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
    policy.voiceRoute = .playerGlobal
    policy.outputProcessingPolicy = .rich
    policy.deadAirAfterFillerEnabled = false
    policy.fillerDirectoryCandidates = []

    let coordinator = TuringStoryWalkiePlaybackCoordinator(
      policy: policy,
      rootURL: rootURL,
      globalPlayer: fakePlayer
    )

    await coordinator.beginRun(
      runID: "test.scriptPoint02.prPreservedOnGenerationFailure",
      expectedSegmentCount: nil
    )
    await coordinator.enqueuePrerecording(
      id: "prologue.walkie.rich.scriptPoint02.001",
      fileURL: URL(fileURLWithPath: "/tmp/pr-rich-script-point-02.mp3")
    )
    await coordinator.setExpectedGeneratedSegmentCount(2)
    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeStarted(segmentIndex: 1)
    await coordinator.qwenComputeSkipped(
      segmentIndex: 0,
      reason: "test generation failure"
    )
    await coordinator.qwenComputeSkipped(
      segmentIndex: 1,
      reason: "test generation failure"
    )
    await coordinator.qwenComputeAllFinished()

    XCTAssertEqual(fakePlayer.startedClips.map(\.kind), [.prerecording])
    XCTAssertTrue(fakePlayer.cancelReasons.isEmpty)

    fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    XCTAssertEqual(fakePlayer.startedClips.map(\.kind), [.prerecording])
    XCTAssertTrue(fakePlayer.cancelReasons.isEmpty)
    let completedCount = await coordinator.completedGeneratedSegmentCount()
    XCTAssertEqual(completedCount, 0)
  }

  private func generatedAudio(index: Int) -> TuringComputeGapGeneratedAudio {
    let samples = (0..<2_400).map { sampleIndex in
      Float(sin(Double(sampleIndex) * 0.02)) * 0.1
    }
    return TuringComputeGapGeneratedAudio(
      segmentIndex: index,
      samples: samples,
      sampleRate: 24_000,
      channelCount: 1
    )
  }

  private func makeFillerDirectory(in rootURL: URL) throws -> URL {
    let directory = rootURL.appendingPathComponent(
      "rich-filler",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data([0]).write(
      to: directory.appendingPathComponent("rich-filler-test_1.mp3")
    )
    return directory
  }

  private func settle() async {
    for _ in 0..<8 {
      await Task.yield()
    }
  }
}
