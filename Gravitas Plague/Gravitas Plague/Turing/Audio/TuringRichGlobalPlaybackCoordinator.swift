import AVFoundation
import Foundation

@MainActor
final class TuringRichGlobalPlaybackCoordinator: TuringGeneratedAudioPlaybackSink {
  struct Policy: Sendable {
    var firstSegmentPrerollFillerCount = 1
    var chainFillerWhileComputeWithoutSpeech = true
    var completeCurrentFillerBeforeGeneratedSpeech = true
    var deadAirAfterFillerEnabled = true
    var deadAirMinSeconds = 0.5
    var deadAirMaxSeconds = 4.0
    var avoidImmediateFillerRepeat = true
    var allowSkippedGeneratedSegments = false

    var generatedGainDB: Float = 0
    var fillerGainDB: Float = -6
    var commSFXGainDB: Float = -6
    var prerecordingGainDB: Float = 0
  }

  enum PlaybackError: LocalizedError {
    case missingRunDirectory
    case emptyGeneratedSamples
    case incompleteGeneratedFrame
    case couldNotAllocatePCMBuffer
    case missingPCMChannelData
    case generatedWAVValidationFailed
    case duplicatePrerecording
    case unexpectedPrerecording
    case playbackFailed(String)
    case generatedSegmentFailed(Int, String)

    var errorDescription: String? {
      switch self {
      case .missingRunDirectory:
        return "Rich playback run directory is missing."
      case .emptyGeneratedSamples:
        return "Rich generated audio is empty."
      case .incompleteGeneratedFrame:
        return "Rich generated audio does not contain a full frame."
      case .couldNotAllocatePCMBuffer:
        return "Could not allocate Rich generated PCM buffer."
      case .missingPCMChannelData:
        return "Rich generated PCM channel data is unavailable."
      case .generatedWAVValidationFailed:
        return "Rich generated WAV validation returned zero frames."
      case .duplicatePrerecording:
        return "Rich playback received more than one prerecording."
      case .unexpectedPrerecording:
        return "Rich playback received a prerecording for a run that did not declare one."
      case .playbackFailed(let label):
        return "Rich global playback failed: \(label)."
      case .generatedSegmentFailed(let index, let reason):
        return "Rich generated segment \(index) failed: \(reason)"
      }
    }
  }

  private struct GeneratedClip {
    let segmentIndex: Int
    let fileURL: URL
    let frameCount: AVAudioFramePosition
    let sampleRate: Double
  }

  private struct PrerecordingClip: Equatable {
    let id: String
    let fileURL: URL
  }

  private enum ActiveItem: Equatable {
    case none
    case walkieOpen(TuringRichGlobalClipHandle)
    case prerecording(
      id: String,
      handle: TuringRichGlobalClipHandle,
      fileURL: URL
    )
    case filler(TuringRichGlobalClipHandle, URL)
    case generated(
      segmentIndex: Int,
      handle: TuringRichGlobalClipHandle,
      fileURL: URL
    )
    case deadAir(UUID)
    case walkieSend(TuringRichGlobalClipHandle)
    case cancelled
  }

  private let policy: Policy
  private let player: any TuringRichGlobalClipPlaying
  private let fillerCatalog: TuringRichFillerCatalog
  private let transmissionProvider: any TuringRichWalkieTransmissionProviding
  private let rootURL: URL

  private var runDirectory: URL?
  private var runActive = false
  private var runID: String?
  private var outputContext: TuringVoiceOutputContext = .roomGlobal
  private var expectedSegmentCount: Int?
  private var playbackGateOpen = true

  private var prerecordingExpected = false
  private var pendingPrerecording: PrerecordingClip?
  private var prerecordingHasPlayed = false
  private var postPrerecordingBridgeFillerAvailable = false

  private var nextPlaybackSegmentIndex = 0
  private var completedGeneratedPlaybackCount = 0
  private var activeComputeSegments = Set<Int>()
  private var pendingGenerated: [Int: GeneratedClip] = [:]
  private var skippedSegments = Set<Int>()
  private var allComputeFinished = false
  private var activeItem: ActiveItem = .none

  private var firstPrerollRemaining = 0
  private var lastFillerURL: URL?
  private var deadAirTask: Task<Void, Never>?

  private var walkieEnvelope: TuringRichWalkieTransmissionEnvelope?
  private var walkieOpenCompleted = false
  private var walkieSendCompleted = false

  private var terminalError: Error?
  private var waitContinuations: [CheckedContinuation<Void, Never>] = []

  init(
    policy: Policy = Policy(),
    player: (any TuringRichGlobalClipPlaying)? = nil,
    fillerCatalog: TuringRichFillerCatalog = TuringRichFillerCatalog(),
    transmissionProvider: any TuringRichWalkieTransmissionProviding =
      TuringRichWalkieTransmissionController(),
    rootURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TuringRichGlobalPlayback",
      isDirectory: true
    )
  ) {
    self.policy = policy
    self.player = player ?? TuringRichRoutedOneShotClipPlayer()
    self.fillerCatalog = fillerCatalog
    self.transmissionProvider = transmissionProvider
    self.rootURL = rootURL
  }

  func beginRun(
    runID: String,
    outputContext: TuringVoiceOutputContext = .roomGlobal,
    expectedSegmentCount: Int?,
    playbackInitiallyBlocked: Bool = false,
    expectsPrerecording: Bool = false
  ) async throws {
    await cancelRun(reason: "beginNewRun")

    self.runID = runID
    self.outputContext = outputContext
    self.expectedSegmentCount = expectedSegmentCount
    playbackGateOpen = playbackInitiallyBlocked == false

    prerecordingExpected = expectsPrerecording
    pendingPrerecording = nil
    prerecordingHasPlayed = false
    postPrerecordingBridgeFillerAvailable = false

    nextPlaybackSegmentIndex = 0
    completedGeneratedPlaybackCount = 0
    activeComputeSegments.removeAll(keepingCapacity: true)
    pendingGenerated.removeAll(keepingCapacity: true)
    skippedSegments.removeAll(keepingCapacity: true)
    allComputeFinished = false
    activeItem = .none
    firstPrerollRemaining = max(0, policy.firstSegmentPrerollFillerCount)
    lastFillerURL = nil
    walkieOpenCompleted = false
    walkieSendCompleted = false
    terminalError = nil

    deadAirTask?.cancel()
    deadAirTask = nil

    if outputContext == .walkieOutgoingHeadset {
      walkieEnvelope = try transmissionProvider.makeEnvelope()
    } else {
      walkieEnvelope = nil
    }

    let safeRunID =
      runID
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    let directory = rootURL.appendingPathComponent(
      safeRunID,
      isDirectory: true
    )

    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    runDirectory = directory
    runActive = true

    print(
      """
      [TuringRichPlayback] run started
        runID: \(runID)
        outputContext: \(outputContext.rawValue)
        expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
        playbackGateOpen: \(playbackGateOpen)
        prerecordingExpected: \(prerecordingExpected)
        walkieEnvelopeEnabled: \(outputContext == .walkieOutgoingHeadset)
        richVoiceRoute: headTrackedSpatial
        richVoiceEmitter: TuringRichHeadset_AudioEmitter
        commSFXRoute: spatialWalkie
        commSFXEmitter: TuringStoryWalkieTalkie_AudioEmitter
        fillerClipCount: \(fillerCatalog.uniqueFileCount)
        weightedFillerEntryCount: \(fillerCatalog.weightedEntryCount)
      """)

    if playbackGateOpen == false {
      print(
        """
        [TuringRichPlayback] playback gate closed
          reason: callerOwnedGate
        """)
    }

    await reconcile(reason: "runStarted")
  }

  func enqueuePrerecording(
    id: String,
    fileURL: URL
  ) async throws {
    guard runActive else {
      return
    }
    guard prerecordingExpected else {
      throw PlaybackError.unexpectedPrerecording
    }
    guard pendingPrerecording == nil,
      prerecordingHasPlayed == false
    else {
      throw PlaybackError.duplicatePrerecording
    }

    pendingPrerecording = PrerecordingClip(
      id: id,
      fileURL: fileURL
    )

    print(
      """
      [TuringRichPlayback] prerecording queued
        id: \(id)
        file: \(fileURL.lastPathComponent)
        route: headTrackedSpatial
        spatialEmitter: TuringRichHeadset_AudioEmitter
        playsAfterOpenComm: \(outputContext == .walkieOutgoingHeadset)
      """)

    await reconcile(reason: "prerecordingQueued")
  }

  func setExpectedGeneratedSegmentCount(_ count: Int) async {
    guard runActive else {
      return
    }

    expectedSegmentCount = max(0, count)
    print(
      """
      [TuringRichPlayback] expected generated count set
        expectedSegmentCount: \(expectedSegmentCount ?? 0)
        nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
      """)
    await reconcile(reason: "expectedGeneratedCountSet")
  }

  func releasePlaybackGate(reason: String) async {
    guard runActive,
      playbackGateOpen == false
    else {
      return
    }

    playbackGateOpen = true

    print(
      """
      [TuringRichPlayback] playback gate opened
        reason: \(reason)
      """)

    await reconcile(reason: "playbackGateReleased.\(reason)")
  }

  func qwenComputeStarted(segmentIndex: Int) async {
    guard runActive else {
      return
    }

    activeComputeSegments.insert(segmentIndex)

    print(
      """
      [TuringRichPlayback] qwen compute started
        segmentIndex: \(segmentIndex)
        prerecordingHasPlayed: \(prerecordingHasPlayed)
      """)

    await reconcile(reason: "computeStarted")
  }

  func qwenComputeFinished(
    segmentIndex: Int,
    audio: TuringComputeGapGeneratedAudio
  ) async {
    guard runActive else {
      return
    }

    activeComputeSegments.remove(segmentIndex)

    do {
      let processed = await TuringQwenOutputPostProcessor.processForPlayback(
        audio,
        policy: .rich,
        reason: "richGlobalPlayback"
      )

      let clip = try writeGeneratedWAV(
        audio: processed,
        segmentIndex: segmentIndex
      )
      pendingGenerated[segmentIndex] = clip

      print(
        """
        [TuringRichPlayback] generated buffered
          segmentIndex: \(segmentIndex)
          file: \(clip.fileURL.lastPathComponent)
          frameCount: \(clip.frameCount)
          prerecordingHasPlayed: \(prerecordingHasPlayed)
          pendingGenerated: \(pendingGenerated.keys.sorted())
        """)
    } catch {
      skippedSegments.insert(segmentIndex)

      print(
        """
        [TuringRichPlayback] generated WAV failed; segment skipped
          segmentIndex: \(segmentIndex)
          error: \(error.localizedDescription)
        """)
    }

    if case .deadAir = activeItem,
      pendingGenerated[nextPlaybackSegmentIndex] != nil
    {
      deadAirTask?.cancel()
      deadAirTask = nil
      activeItem = .none

      print(
        """
        [TuringRichPlayback] dead air cancelled
          reason: generatedReady
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)
    }

    await reconcile(reason: "computeFinished")
  }

  func qwenComputeSkipped(
    segmentIndex: Int,
    reason: String
  ) async {
    guard runActive else {
      return
    }

    activeComputeSegments.remove(segmentIndex)

    guard policy.allowSkippedGeneratedSegments else {
      print(
        """
        [TuringRichPlayback] qwen segment failure rejected
          segmentIndex: \(segmentIndex)
          reason: \(reason)
          runMayAdvanceFromPROnly: false
        """)
      failRun(
        PlaybackError.generatedSegmentFailed(segmentIndex, reason)
      )
      return
    }

    skippedSegments.insert(segmentIndex)

    print(
      """
      [TuringRichPlayback] qwen compute skipped
        segmentIndex: \(segmentIndex)
        reason: \(reason)
      """)

    await reconcile(reason: "computeSkipped")
  }

  func qwenComputeAllFinished() async {
    guard runActive else {
      return
    }

    allComputeFinished = true
    print("[TuringRichPlayback] qwen compute all finished")
    await reconcile(reason: "computeAllFinished")
  }

  func waitUntilPlaybackFinished() async {
    if runActive == false {
      return
    }

    await withCheckedContinuation { continuation in
      waitContinuations.append(continuation)
    }
  }

  func throwIfFailed() throws {
    if let terminalError {
      throw terminalError
    }
  }

  func completedGeneratedSegmentCount() -> Int {
    completedGeneratedPlaybackCount
  }

  func cancelRun(reason: String) async {
    guard runActive || activeItem != .none else {
      return
    }

    runActive = false
    activeItem = .cancelled
    deadAirTask?.cancel()
    deadAirTask = nil
    player.cancelActive(reason: reason)

    cleanupAllWAVs(reason: "cancel.\(reason)")
    pendingGenerated.removeAll(keepingCapacity: false)
    pendingPrerecording = nil
    activeComputeSegments.removeAll(keepingCapacity: false)
    skippedSegments.removeAll(keepingCapacity: false)

    print(
      """
      [TuringRichPlayback] run cancelled
        reason: \(reason)
      """)

    resumeWaiters()
  }

  private func reconcile(reason: String) async {
    guard runActive,
      playbackGateOpen,
      activeItem == .none
    else {
      return
    }

    while skippedSegments.remove(nextPlaybackSegmentIndex) != nil {
      print(
        """
        [TuringRichPlayback] skipped segment advanced
          segmentIndex: \(nextPlaybackSegmentIndex)
        """)
      nextPlaybackSegmentIndex += 1
    }

    if outputContext == .walkieOutgoingHeadset,
      walkieOpenCompleted == false
    {
      await startWalkieOpen(reason: reason)
      return
    }

    if prerecordingExpected,
      prerecordingHasPlayed == false
    {
      guard let prerecording = pendingPrerecording else {
        return
      }

      pendingPrerecording = nil
      await startPrerecording(
        prerecording,
        reason: reason
      )
      return
    }

    if firstPrerollRemaining > 0,
      pendingGenerated[nextPlaybackSegmentIndex] != nil
    {
      firstPrerollRemaining -= 1

      if await startFiller(reason: "firstSegmentPreroll") {
        return
      }
    }

    if let clip = pendingGenerated.removeValue(
      forKey: nextPlaybackSegmentIndex
    ) {
      await startGenerated(
        clip,
        reason: reason
      )
      return
    }

    if generationAndPlaybackBodyFinished {
      if outputContext == .walkieOutgoingHeadset,
        walkieSendCompleted == false
      {
        await startWalkieSend(reason: reason)
        return
      }

      finishRun(reason: "allDone")
      return
    }

    if activeComputeSegments.isEmpty == false,
      policy.chainFillerWhileComputeWithoutSpeech
    {
      if prerecordingHasPlayed,
        nextPlaybackSegmentIndex == 0,
        pendingGenerated[0] == nil,
        postPrerecordingBridgeFillerAvailable
      {
        postPrerecordingBridgeFillerAvailable = false

        if await startFiller(reason: "postPrerecordingComputeBridge") {
          return
        }
      }

      if nextPlaybackSegmentIndex == 0,
        pendingGenerated[0] == nil
      {
        if policy.deadAirAfterFillerEnabled {
          startDeadAir(reason: "initialGeneratedSegmentWaiting")
        }
        return
      }

      if await startFiller(reason: "computeWithoutSpeech") == false,
        policy.deadAirAfterFillerEnabled
      {
        startDeadAir(reason: "missingFiller")
      }
    }
  }

  private func startWalkieOpen(reason: String) async {
    guard let envelope = walkieEnvelope else {
      failRun(
        PlaybackError.playbackFailed(
          "missing outgoing walkie envelope"
        )
      )
      return
    }

    do {
      let handle = try player.play(
        fileURL: envelope.openURL,
        kind: .walkieOpen,
        label: "open-comm",
        gainDB: policy.commSFXGainDB,
        completion: { [weak self] handle, success in
          Task { @MainActor in
            await self?.clipCompleted(
              handle: handle,
              successfully: success
            )
          }
        }
      )

      activeItem = .walkieOpen(handle)

      print(
        """
        [TuringRichPlayback] walkie open started
          reason: \(reason)
          route: spatialWalkie
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
        """)
    } catch {
      failRun(error)
    }
  }

  private func startPrerecording(
    _ clip: PrerecordingClip,
    reason: String
  ) async {
    do {
      let handle = try player.play(
        fileURL: clip.fileURL,
        kind: .prerecording,
        label: clip.id,
        gainDB: policy.prerecordingGainDB,
        completion: { [weak self] handle, success in
          Task { @MainActor in
            await self?.clipCompleted(
              handle: handle,
              successfully: success
            )
          }
        }
      )

      activeItem = .prerecording(
        id: clip.id,
        handle: handle,
        fileURL: clip.fileURL
      )

      print(
        """
        [TuringRichPlayback] prerecording started
          id: \(clip.id)
          reason: \(reason)
          file: \(clip.fileURL.lastPathComponent)
          route: headTrackedSpatial
          spatialEmitter: TuringRichHeadset_AudioEmitter
          completionSource: AudioPlaybackController.completionHandler
        """)
    } catch {
      failRun(error)
    }
  }

  private func startWalkieSend(reason: String) async {
    guard let envelope = walkieEnvelope else {
      failRun(
        PlaybackError.playbackFailed(
          "missing outgoing walkie envelope"
        )
      )
      return
    }

    do {
      let handle = try player.play(
        fileURL: envelope.sendURL,
        kind: .walkieSend,
        label: "send-comm",
        gainDB: policy.commSFXGainDB,
        completion: { [weak self] handle, success in
          Task { @MainActor in
            await self?.clipCompleted(
              handle: handle,
              successfully: success
            )
          }
        }
      )

      activeItem = .walkieSend(handle)

      print(
        """
        [TuringRichPlayback] walkie send started
          reason: \(reason)
          route: spatialWalkie
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
        """)
    } catch {
      failRun(error)
    }
  }

  @discardableResult
  private func startFiller(reason: String) async -> Bool {
    guard
      let fillerURL = fillerCatalog.randomURL(
        avoiding: policy.avoidImmediateFillerRepeat ? lastFillerURL : nil
      )
    else {
      print(
        """
        [TuringRichPlayback] filler unavailable
          reason: \(reason)
          fallbackToBigMikeFiller: false
        """)
      return false
    }

    do {
      let handle = try player.play(
        fileURL: fillerURL,
        kind: .filler,
        label: fillerURL.deletingPathExtension().lastPathComponent,
        gainDB: policy.fillerGainDB,
        completion: { [weak self] handle, success in
          Task { @MainActor in
            await self?.clipCompleted(
              handle: handle,
              successfully: success
            )
          }
        }
      )

      lastFillerURL = fillerURL
      activeItem = .filler(
        handle,
        fillerURL
      )

      print(
        """
        [TuringRichPlayback] filler started
          reason: \(reason)
          clip: \(fillerURL.lastPathComponent)
          route: headTrackedSpatial
          spatialEmitter: TuringRichHeadset_AudioEmitter
        """)

      return true
    } catch {
      print(
        """
        [TuringRichPlayback] filler start failed
          reason: \(reason)
          error: \(error.localizedDescription)
        """)
      return false
    }
  }

  private func startGenerated(
    _ clip: GeneratedClip,
    reason: String
  ) async {
    do {
      let handle = try player.play(
        fileURL: clip.fileURL,
        kind: .generated,
        label: String(
          format: "segment_%04d",
          clip.segmentIndex
        ),
        gainDB: policy.generatedGainDB,
        completion: { [weak self] handle, success in
          Task { @MainActor in
            await self?.clipCompleted(
              handle: handle,
              successfully: success
            )
          }
        }
      )

      activeItem = .generated(
        segmentIndex: clip.segmentIndex,
        handle: handle,
        fileURL: clip.fileURL
      )

      print(
        """
        [TuringRichPlayback] generated playback started
          segmentIndex: \(clip.segmentIndex)
          reason: \(reason)
          file: \(clip.fileURL.lastPathComponent)
          frameCount: \(clip.frameCount)
          sampleRate: \(clip.sampleRate)
          route: headTrackedSpatial
          spatialEmitter: TuringRichHeadset_AudioEmitter
        """)
    } catch {
      cleanupWAV(
        clip.fileURL,
        reason: "generatedStartFailed"
      )
      failRun(error)
    }
  }

  private func startDeadAir(reason: String) {
    guard activeItem == .none else {
      return
    }

    let minimum = min(
      policy.deadAirMinSeconds,
      policy.deadAirMaxSeconds
    )
    let maximum = max(
      policy.deadAirMinSeconds,
      policy.deadAirMaxSeconds
    )
    let seconds = Double.random(in: minimum...maximum)
    let id = UUID()

    activeItem = .deadAir(id)

    print(
      """
      [TuringRichPlayback] dead air started
        id: \(id.uuidString)
        reason: \(reason)
        seconds: \(String(format: "%.2f", seconds))
      """)

    deadAirTask = Task { [weak self] in
      try? await Task.sleep(
        nanoseconds: UInt64(
          seconds * 1_000_000_000
        )
      )

      guard Task.isCancelled == false else {
        return
      }

      await self?.deadAirFinished(id: id)
    }
  }

  private func deadAirFinished(id: UUID) async {
    guard activeItem == .deadAir(id) else {
      return
    }

    activeItem = .none
    deadAirTask = nil

    print(
      """
      [TuringRichPlayback] dead air finished
        id: \(id.uuidString)
      """)

    await reconcile(reason: "deadAirFinished")
  }

  private func clipCompleted(
    handle: TuringRichGlobalClipHandle,
    successfully: Bool
  ) async {
    switch activeItem {
    case .walkieOpen(let activeHandle)
    where activeHandle == handle:
      guard successfully else {
        failRun(
          PlaybackError.playbackFailed("open-comm")
        )
        return
      }

      activeItem = .none
      walkieOpenCompleted = true

      print(
        """
        [TuringRichPlayback] walkie open completed
          completionSource: AudioPlaybackController.completionHandler
        """)

      await reconcile(reason: "walkieOpenCompleted")

    case .prerecording(
      let id,
      let activeHandle,
      let fileURL
    )
    where activeHandle == handle:
      guard successfully else {
        failRun(
          PlaybackError.playbackFailed(
            "Rich prerecording \(id)"
          )
        )
        return
      }

      activeItem = .none
      prerecordingHasPlayed = true
      firstPrerollRemaining = 0
      postPrerecordingBridgeFillerAvailable = true

      print(
        """
        [TuringRichPlayback] prerecording completed
          id: \(id)
          file: \(fileURL.lastPathComponent)
          route: headTrackedSpatial
          spatialEmitter: TuringRichHeadset_AudioEmitter
          completionSource: AudioPlaybackController.completionHandler
          suppressMandatoryInitialFiller: true
        """)

      await reconcile(reason: "prerecordingCompleted")

    case .filler(let activeHandle, _)
    where activeHandle == handle:
      activeItem = .none

      print(
        """
        [TuringRichPlayback] filler completed
          successfully: \(successfully)
          completionSource: AudioPlaybackController.completionHandler
        """)

      if pendingGenerated[nextPlaybackSegmentIndex] == nil,
        activeComputeSegments.isEmpty == false,
        policy.deadAirAfterFillerEnabled
      {
        startDeadAir(reason: "afterFiller")
        return
      }

      await reconcile(reason: "fillerCompleted")

    case .generated(
      let index,
      let activeHandle,
      let fileURL
    )
    where activeHandle == handle:
      guard successfully else {
        failRun(
          PlaybackError.playbackFailed(
            "generated segment \(index)"
          )
        )
        return
      }

      activeItem = .none
      cleanupWAV(
        fileURL,
        reason: "generatedPlaybackCompleted"
      )
      nextPlaybackSegmentIndex = index + 1
      completedGeneratedPlaybackCount += 1

      print(
        """
        [TuringRichPlayback] generated playback completed
          segmentIndex: \(index)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          completedGeneratedPlaybackCount: \(completedGeneratedPlaybackCount)
          completionSource: AudioPlaybackController.completionHandler
          successfully: true
        """)

      await reconcile(reason: "generatedCompleted")

    case .walkieSend(let activeHandle)
    where activeHandle == handle:
      guard successfully else {
        failRun(
          PlaybackError.playbackFailed("send-comm")
        )
        return
      }

      activeItem = .none
      walkieSendCompleted = true

      print(
        """
        [TuringRichPlayback] walkie send completed
          completionSource: AudioPlaybackController.completionHandler
        """)

      await reconcile(reason: "walkieSendCompleted")

    default:
      print(
        """
        [TuringRichPlayback] stale completion ignored
          handleID: \(handle.id.uuidString)
        """)
    }
  }

  private var generationAndPlaybackBodyFinished: Bool {
    guard allComputeFinished,
      activeComputeSegments.isEmpty,
      pendingGenerated.isEmpty,
      skippedSegments.isEmpty
    else {
      return false
    }

    if prerecordingExpected,
      prerecordingHasPlayed == false
    {
      return false
    }

    if let expectedSegmentCount {
      return nextPlaybackSegmentIndex >= expectedSegmentCount
    }

    return true
  }

  private func failRun(_ error: Error) {
    terminalError = error
    runActive = false
    activeItem = .cancelled
    deadAirTask?.cancel()
    deadAirTask = nil
    player.cancelActive(reason: "failure")
    cleanupAllWAVs(reason: "failure")

    print(
      """
      [TuringRichPlayback] run failed
        runID: \(runID ?? "nil")
        error: \(error.localizedDescription)
      """)

    resumeWaiters()
  }

  private func finishRun(reason: String) {
    guard runActive else {
      return
    }

    runActive = false
    cleanupAllWAVs(reason: "finish.\(reason)")

    print(
      """
      [TuringRichPlayback] run finished
        runID: \(runID ?? "nil")
        reason: \(reason)
        outputContext: \(outputContext.rawValue)
        richVoiceRoute: headTrackedSpatial
        richVoiceEmitter: TuringRichHeadset_AudioEmitter
        commSFXRoute: spatialWalkie
        commSFXEmitter: TuringStoryWalkieTalkie_AudioEmitter
      """)

    resumeWaiters()
  }

  private func resumeWaiters() {
    let continuations = waitContinuations
    waitContinuations.removeAll(keepingCapacity: false)

    for continuation in continuations {
      continuation.resume()
    }
  }

  private func writeGeneratedWAV(
    audio: TuringComputeGapGeneratedAudio,
    segmentIndex: Int
  ) throws -> GeneratedClip {
    guard let runDirectory else {
      throw PlaybackError.missingRunDirectory
    }
    guard audio.samples.isEmpty == false else {
      throw PlaybackError.emptyGeneratedSamples
    }

    let channelCount = max(
      1,
      Int(audio.channelCount)
    )
    let frameCount = audio.samples.count / channelCount

    guard frameCount > 0 else {
      throw PlaybackError.incompleteGeneratedFrame
    }

    let finalURL = runDirectory.appendingPathComponent(
      String(
        format: "segment_%04d.wav",
        segmentIndex
      )
    )
    let temporaryURL = runDirectory.appendingPathComponent(
      String(
        format: "segment_%04d.tmp.wav",
        segmentIndex
      )
    )

    try? FileManager.default.removeItem(at: temporaryURL)
    try? FileManager.default.removeItem(at: finalURL)

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: audio.sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: true,
    ]

    try autoreleasepool {
      let file = try AVAudioFile(
        forWriting: temporaryURL,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )

      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: AVAudioFrameCount(frameCount)
        )
      else {
        throw PlaybackError.couldNotAllocatePCMBuffer
      }

      buffer.frameLength = AVAudioFrameCount(frameCount)

      guard let channels = buffer.floatChannelData else {
        throw PlaybackError.missingPCMChannelData
      }

      if channelCount == 1 {
        for index in 0..<frameCount {
          let value = audio.samples[index]
          channels[0][index] =
            value.isFinite
            ? max(-1, min(1, value))
            : 0
        }
      } else {
        for channelIndex in 0..<channelCount {
          for frameIndex in 0..<frameCount {
            let value = audio.samples[
              frameIndex * channelCount + channelIndex
            ]
            channels[channelIndex][frameIndex] =
              value.isFinite
              ? max(-1, min(1, value))
              : 0
          }
        }
      }

      try file.write(from: buffer)
    }

    try FileManager.default.moveItem(
      at: temporaryURL,
      to: finalURL
    )

    let validation = try AVAudioFile(
      forReading: finalURL
    )
    let sampleRate = validation.fileFormat.sampleRate

    guard validation.length > 0,
      sampleRate > 0
    else {
      throw PlaybackError.generatedWAVValidationFailed
    }

    return GeneratedClip(
      segmentIndex: segmentIndex,
      fileURL: finalURL,
      frameCount: validation.length,
      sampleRate: sampleRate
    )
  }

  private func cleanupWAV(
    _ url: URL,
    reason: String
  ) {
    try? FileManager.default.removeItem(at: url)

    print(
      """
      [TuringRichPlayback] generated WAV cleaned
        file: \(url.lastPathComponent)
        reason: \(reason)
      """)
  }

  private func cleanupAllWAVs(reason: String) {
    for clip in pendingGenerated.values {
      cleanupWAV(
        clip.fileURL,
        reason: reason
      )
    }

    if let runDirectory {
      try? FileManager.default.removeItem(at: runDirectory)
    }

    runDirectory = nil
  }
}
