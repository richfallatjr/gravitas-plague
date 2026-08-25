import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringStoryWalkiePlaybackCoordinatorRichTests: XCTestCase {
  func testBigMikeTuringFlowRequiresFillerBetweenPRAndGeneratedTTS() {
    let policy = TuringStoryWalkiePlaybackCoordinator
      .bigMikeTuringFlowPolicy

    XCTAssertEqual(policy.voiceRoute.rawValue, "walkieSpatial")
    XCTAssertEqual(policy.firstSegmentPrerollFillerCount, 1)
    XCTAssertTrue(policy.chainFillerFromPrerecordingToFirstGenerated)
    XCTAssertTrue(policy.completeCurrentFillerBeforeGeneratedSpeech)
    XCTAssertEqual(policy.generatedGainDB, 0)
    XCTAssertEqual(policy.prerecordingGainDB, 0)
    XCTAssertEqual(policy.fillerGainDB, -6)
  }

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
      endpoint: fakePlayer
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

    var startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(startedKinds, [.prerecording])

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

    startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(startedKinds, [.prerecording])

    await fakePlayer.completeActive()
    await settle()
    var lastKind = await fakePlayer.lastStartedKind()
    XCTAssertEqual(lastKind, .filler)

    await fakePlayer.completeActive()
    await settle()
    var lastLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(lastLabel, "segment_0000")

    await fakePlayer.completeActive()
    await settle()
    lastLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(lastLabel, "segment_0001")

    await fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(
      startedKinds,
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
      endpoint: fakePlayer
    )

    await coordinator.beginRun(
      runID: "test.scriptPoint02.continuousPRBridge",
      expectedSegmentCount: nil
    )
    await coordinator.enqueuePrerecording(
      id: "prologue.walkie.rich.scriptPoint02.001",
      fileURL: URL(fileURLWithPath: "/tmp/pr-rich-script-point-02.mp3")
    )

    await fakePlayer.completeActive()
    await settle()
    var startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(startedKinds, [.prerecording, .filler])

    await fakePlayer.completeActive()
    await settle()
    startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(
      startedKinds,
      [.prerecording, .filler, .filler]
    )

    await coordinator.setExpectedGeneratedSegmentCount(1)
    await coordinator.qwenComputeStarted(segmentIndex: 0)
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeAllFinished()

    var lastKind = await fakePlayer.lastStartedKind()
    XCTAssertEqual(lastKind, .filler)
    await fakePlayer.completeActive()
    await settle()
    lastKind = await fakePlayer.lastStartedKind()
    XCTAssertEqual(lastKind, .generated)

    await fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()
    startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(
      startedKinds,
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
      endpoint: fakePlayer
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

    var startedKinds = await fakePlayer.startedKinds()
    var cancelReasons = await fakePlayer.cancelReasonsSnapshot()
    XCTAssertEqual(startedKinds, [.prerecording])
    XCTAssertTrue(cancelReasons.isEmpty)

    await fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    startedKinds = await fakePlayer.startedKinds()
    cancelReasons = await fakePlayer.cancelReasonsSnapshot()
    XCTAssertEqual(startedKinds, [.prerecording])
    XCTAssertTrue(cancelReasons.isEmpty)
    let completedCount = await coordinator.completedGeneratedSegmentCount()
    XCTAssertEqual(completedCount, 0)
  }

  func testTerminalRendererFailureCannotLeavePRFlowWaitingForever()
    async throws
  {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
    policy.voiceRoute = .playerGlobal
    policy.deadAirAfterFillerEnabled = false
    policy.fillerDirectoryCandidates = []

    let coordinator = TuringStoryWalkiePlaybackCoordinator(
      policy: policy,
      rootURL: rootURL,
      endpoint: fakePlayer
    )

    await coordinator.beginRun(
      runID: "test.scriptPoint03.terminalRendererFailure",
      expectedSegmentCount: nil
    )
    await coordinator.enqueuePrerecording(
      id: "prologue.walkie.bigMike.scriptPoint03.001",
      fileURL: URL(fileURLWithPath: "/tmp/pr-big-mike-script-point-03.mp3")
    )
    await coordinator.setExpectedGeneratedSegmentCount(3)
    await coordinator.qwenComputeFailed(
      expectedSegmentCount: 3,
      reason: "test warm-load failure"
    )

    let startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(startedKinds, [.prerecording])
    await fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    let cancelReasons = await fakePlayer.cancelReasonsSnapshot()
    XCTAssertTrue(cancelReasons.isEmpty)
    let completedCount = await coordinator.completedGeneratedSegmentCount()
    XCTAssertEqual(completedCount, 0)
  }

  func testGeneratedPlaybackStartsImmediatelyAndFillerBridgesMissingIndex()
    async throws
  {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fillerDirectory = try makeFillerDirectory(in: rootURL)
    var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
    policy.firstSegmentPrerollFillerCount = 0
    policy.chainFillerFromPrerecordingToFirstGenerated = false
    policy.chainFillerWhileComputeWithoutSpeech = true
    policy.deadAirAfterFillerEnabled = false
    policy.fillerDirectoryCandidates = [fillerDirectory.path]

    let coordinator = TuringStoryWalkiePlaybackCoordinator(
      policy: policy,
      rootURL: rootURL,
      endpoint: fakePlayer
    )
    await coordinator.beginRun(
      runID: "test.sharedPlayback.immediateOrdered",
      expectedSegmentCount: nil
    )
    await coordinator.enqueuePrerecording(
      id: "test.sharedPlayback.pr",
      fileURL: URL(fileURLWithPath: "/tmp/shared-playback-pr.mp3")
    )

    for index in 0...10 {
      await coordinator.qwenComputeStarted(segmentIndex: index)
    }
    await coordinator.qwenComputeFinished(
      segmentIndex: 0,
      audio: generatedAudio(index: 0)
    )
    await coordinator.qwenComputeFinished(
      segmentIndex: 2,
      audio: generatedAudio(index: 2)
    )

    var startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(startedKinds, [.prerecording])

    await fakePlayer.completeActive()
    await settle()
    var startedLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(startedLabel, "segment_0000")

    await fakePlayer.completeActive()
    await settle()
    startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(startedKinds, [.prerecording, .generated, .filler])

    await coordinator.qwenComputeFinished(
      segmentIndex: 1,
      audio: generatedAudio(index: 1)
    )
    for index in 3...10 {
      await coordinator.qwenComputeSkipped(
        segmentIndex: index,
        reason: "controlled test tail"
      )
    }
    await settle()
    let startedKind = await fakePlayer.lastStartedKind()
    XCTAssertEqual(startedKind, .filler)

    await coordinator.qwenComputeAllFinished()
    await fakePlayer.completeActive()
    await settle()
    startedLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(startedLabel, "segment_0001")

    await fakePlayer.completeActive()
    await settle()
    startedLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(startedLabel, "segment_0002")

    await fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(
      startedKinds,
      [.prerecording, .generated, .filler, .generated, .generated]
    )
    await coordinator.runCancelled(reason: "testComplete")
  }

  func testAuthoredBridgePlaysBetweenScriptVoiceAndPromptVoiceIndexes()
    async throws
  {
    let fakePlayer = FakeRichGlobalClipPlayer()
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    var policy = TuringStoryWalkiePlaybackCoordinator.Policy()
    policy.firstSegmentPrerollFillerCount = 0
    policy.chainFillerFromPrerecordingToFirstGenerated = false
    policy.chainFillerWhileComputeWithoutSpeech = false
    policy.deadAirAfterFillerEnabled = false
    policy.fillerDirectoryCandidates = []

    let coordinator = TuringStoryWalkiePlaybackCoordinator(
      policy: policy,
      rootURL: rootURL,
      endpoint: fakePlayer
    )
    await coordinator.beginRun(
      runID: "test.scriptPoint05.authoredBridge",
      expectedSegmentCount: nil
    )
    await coordinator.enqueuePrerecording(
      id: "test.scriptPoint05.pr1",
      fileURL: URL(fileURLWithPath: "/tmp/test-script05-pr1.mp3")
    )
    await coordinator.enqueueAuthoredBridge(
      id: "test.scriptPoint05.pr2",
      fileURL: URL(fileURLWithPath: "/tmp/test-script05-pr2.mp3"),
      beforeGeneratedSegmentIndex: 1
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
    await coordinator.sealGeneratedInput(finalExpectedSegmentCount: 2)

    await fakePlayer.completeActive()
    await settle()
    var lastLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(lastLabel, "segment_0000")

    await fakePlayer.completeActive()
    await settle()
    lastLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(lastLabel, "test.scriptPoint05.pr2")

    await fakePlayer.completeActive()
    await settle()
    lastLabel = await fakePlayer.lastStartedLabel()
    XCTAssertEqual(lastLabel, "segment_0001")

    await fakePlayer.completeActive()
    await coordinator.waitUntilPlaybackFinished()

    let startedKinds = await fakePlayer.startedKinds()
    XCTAssertEqual(
      startedKinds,
      [.prerecording, .generated, .prerecording, .generated]
    )
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
