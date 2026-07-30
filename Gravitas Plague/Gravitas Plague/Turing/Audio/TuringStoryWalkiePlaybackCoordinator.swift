import AVFoundation
import Foundation

actor TuringStoryWalkiePlaybackCoordinator {
    enum VoiceRoute: String, Sendable {
        case walkieSpatial
        case playerGlobal
        case playerHeadTracked
        case crankRadioSpatial
        case hamReceiverSpatial
    }

    struct Policy: Sendable {
        var firstSegmentPrerollFillerCount = 1
        var chainFillerFromPrerecordingToFirstGenerated = false
        var chainFillerWhileComputeWithoutSpeech = true
        var completeCurrentFillerBeforeGeneratedSpeech = true
        var deadAirAfterFillerEnabled = true
        var deadAirMinSeconds = 0.5
        var deadAirMaxSeconds = 4.0
        var avoidImmediateFillerRepeat = true
        var voiceRoute: VoiceRoute = .walkieSpatial
        var outputProcessingPolicy = TuringQwenOutputProcessingPolicy.bigMike
        var generatedGainDB: Float = 0
        var prerecordingGainDB: Float = -6
        var fillerGainDB: Float = -6
        var stopSendingStaticBeforeGeneratedSegmentZero = false
        var prerecordingPrecedesGenerated = false
        var externalGeneratedGapBridge:
            (any TuringGeneratedGapBridge)?
        var fillerDirectoryCandidates = [
            "Turing/Audio/big-mike-filler",
            "Turing/big-mike-filler",
            "big-mike-filler"
        ]
        var fillerExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "caf"]
    }

    private typealias GeneratedClip =
        TuringGeneratedPlaybackFileStore.PreparedClip

    private struct PrerecordingClip {
        let id: String
        let fileURL: URL
    }

    private struct AuthoredBridgeClip {
        let id: String
        let fileURL: URL
        let beforeGeneratedSegmentIndex: Int
    }

    private enum ActiveItem: Equatable {
        case none
        case prerecording(
            id: String,
            handle: TuringAudioPlaybackHandle,
            fileURL: URL,
            startedAt: Date
        )
        case authoredBridge(
            id: String,
            beforeGeneratedSegmentIndex: Int,
            handle: TuringAudioPlaybackHandle,
            fileURL: URL,
            startedAt: Date
        )
        case generated(
            segmentIndex: Int,
            handle: TuringAudioPlaybackHandle,
            fileURL: URL,
            startedAt: Date
        )
        case filler(
            handle: TuringAudioPlaybackHandle,
            fileURL: URL,
            startedAt: Date
        )
        case deadAir(id: UUID)
        case cancelled

        var handle: TuringAudioPlaybackHandle? {
            switch self {
            case .prerecording(_, let handle, _, _),
                 .authoredBridge(_, _, let handle, _, _),
                 .generated(_, let handle, _, _),
                 .filler(let handle, _, _):
                return handle
            case .none, .deadAir, .cancelled:
                return nil
            }
        }
    }

    private let policy: Policy
    private let endpoint: any TuringAudioPlaybackEndpoint
    private let fileStore: TuringGeneratedPlaybackFileStore
    private let fillerCatalog = TuringFillerCatalogActor()
    private var runActive = false
    private var runID: String?
    private var flowIdentity: TuringFlowIdentity?
    private var acceptedPrerecordingID: String?
    private var expectedSegmentCount: Int?
    private var nextPlaybackSegmentIndex = 0
    private var completedGeneratedPlaybackCount = 0
    private var activeComputeSegments = Set<Int>()
    private var pendingGenerated: [Int: GeneratedClip] = [:]
    private var pendingPrerecording: PrerecordingClip?
    private var pendingAuthoredBridges:
        [Int: [AuthoredBridgeClip]] = [:]
    private var acceptedAuthoredBridgeIDs = Set<String>()
    private var prerecordingExpected = false
    private var prerecordingHasPlayed = false
    private var skippedSegments = Set<Int>()
    private var allComputeFinished = false
    private var activeItem: ActiveItem = .none
    private var firstPrerollRemaining = 0
    private var lastFillerURL: URL?
    private var deadAirTask: Task<Void, Never>?
    private var endpointEventTask: Task<Void, Never>?
    private var waitContinuations: [CheckedContinuation<Void, Never>] = []
    private var fillerFiles: [URL]

    init(
        policy: Policy = Policy(),
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TuringStoryWalkiePlayback", isDirectory: true),
        endpoint: any TuringAudioPlaybackEndpoint
    ) {
        self.policy = policy
        self.endpoint = endpoint
        self.fileStore = TuringGeneratedPlaybackFileStore(rootURL: rootURL)
        self.fillerFiles = []
    }

    @MainActor
    static func makeBigMikeCoordinator() -> TuringStoryWalkiePlaybackCoordinator {
        TuringStoryWalkiePlaybackCoordinator(
            endpoint: TuringStoryWalkieAudioRoute.makeActiveEndpoint()
                ?? TuringUnavailableAudioEndpoint(
                    message: "Story walkie spatial endpoint is not installed."
                )
        )
    }

    @MainActor
    static func makeBigMikeTuringFlowCoordinator()
        -> TuringStoryWalkiePlaybackCoordinator
    {
        TuringStoryWalkiePlaybackCoordinator(
            policy: bigMikeTuringFlowPolicy,
            endpoint: TuringStoryWalkieAudioRoute.makeActiveEndpoint()
                ?? TuringUnavailableAudioEndpoint(
                    message: "Story walkie spatial endpoint is not installed."
                )
        )
    }

    static var bigMikeTuringFlowPolicy: Policy {
        var policy = Policy()
        policy.chainFillerFromPrerecordingToFirstGenerated = true
        return policy
    }

    @MainActor
    static func makeRichGlobalCoordinator() -> TuringStoryWalkiePlaybackCoordinator {
        var policy = Policy()
        policy.voiceRoute = .playerHeadTracked
        policy.outputProcessingPolicy = .rich
        policy.chainFillerFromPrerecordingToFirstGenerated = true
        policy.generatedGainDB = -5
        policy.prerecordingGainDB = -5
        policy.fillerGainDB = -11
        policy.fillerDirectoryCandidates = TuringRichVoiceIdentity
            .fillerDirectoryCandidates

        return TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TuringRichStoryPlayback",
                    isDirectory: true
                ),
            endpoint: TuringRichHeadsetAudioRoute.makeActiveEndpoint()
                ?? TuringUnavailableAudioEndpoint(
                    message: "Rich head-tracked endpoint is not installed."
                )
        )
    }

    func configureFlowIdentity(_ identity: TuringFlowIdentity) async {
        flowIdentity = identity
    }

    func beginRun(runID: String, expectedSegmentCount: Int?) async {
        await runCancelled(reason: "beginNewRun")

        await startEndpointEventPumpIfNeeded()

        self.runID = runID
        self.acceptedPrerecordingID = nil
        self.expectedSegmentCount = expectedSegmentCount
        self.nextPlaybackSegmentIndex = 0
        self.completedGeneratedPlaybackCount = 0
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.pendingPrerecording = nil
        self.pendingAuthoredBridges.removeAll(keepingCapacity: true)
        self.acceptedAuthoredBridgeIDs.removeAll(keepingCapacity: true)
        self.prerecordingExpected =
            policy.prerecordingPrecedesGenerated
        self.prerecordingHasPlayed = false
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.allComputeFinished = false
        self.activeItem = .none
        self.firstPrerollRemaining = max(0, policy.firstSegmentPrerollFillerCount)
        self.deadAirTask?.cancel()
        self.deadAirTask = nil
        self.runActive = true

        do {
            _ = try await fileStore.beginRun(runID)
            fillerFiles = try await fillerCatalog.catalog(
                characterID: policy.outputProcessingPolicy.voiceID,
                directoryCandidates: policy.fillerDirectoryCandidates,
                extensions: policy.fillerExtensions
            ).weightedURLs
        } catch {
            print("[TuringAudioOffload] run preparation failed error=\(error.localizedDescription)")
            fillerFiles = []
        }

        print("""
        [TuringPlaybackRebuild] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          playbackOwner: TuringStoryWalkiePlaybackCoordinator
          voiceRoute: \(policy.voiceRoute.rawValue)
          spatialEmitter: \(voiceEmitterLogName)
          completionSource: \(completionSourceLogName)
          outputVoiceID: \(policy.outputProcessingPolicy.voiceID)
          qwenScheduler: fresh2
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          chainFillerFromPrerecordingToFirstGenerated: \(policy.chainFillerFromPrerecordingToFirstGenerated)
          prerecordingPrecedesGenerated: \(policy.prerecordingPrecedesGenerated)
          externalGeneratedGapBridge: \(policy.externalGeneratedGapBridge.map { String(reflecting: type(of: $0)) } ?? "none")
        """)

        await reconcile(reason: "runStarted")
    }

    func expectPrerecordingBeforeGenerated() async {
        guard runActive, prerecordingHasPlayed == false else { return }
        prerecordingExpected = true
        print("""
        [TuringStagedSpeech] prerecording playback reserved
          runID: \(runID ?? "none")
          generatedPlaybackHeldUntilPrerecordingQueued: true
        """)
    }

    func enqueuePrerecording(id: String, fileURL: URL) async {
        guard runActive else { return }
        guard acceptedPrerecordingID == nil else {
            if let flowIdentity {
                TuringFlowLog.event(
                    "duplicate prerecording enqueue ignored",
                    identity: flowIdentity,
                    fields: [
                        ("acceptedPrerecordingID", acceptedPrerecordingID ?? "none"),
                        ("rejectedPrerecordingID", id)
                    ]
                )
            }
            return
        }
        acceptedPrerecordingID = id
        prerecordingExpected = false
        pendingPrerecording = PrerecordingClip(
            id: id,
            fileURL: fileURL
        )
        print("""
        [TuringPlaybackRebuild] prerecording queued
          id: \(id)
          file: \(fileURL.lastPathComponent)
          playsBeforeGenerated: true
        """)
        if let flowIdentity {
            TuringFlowLog.event(
                "prerecording enqueued",
                identity: flowIdentity,
                fields: [("file", fileURL.lastPathComponent)]
            )
        }
        await reconcile(reason: "prerecordingQueued")
    }

    func enqueueAuthoredBridge(
        id: String,
        fileURL: URL,
        beforeGeneratedSegmentIndex: Int
    ) async {
        guard runActive else { return }
        guard beforeGeneratedSegmentIndex >= nextPlaybackSegmentIndex else {
            print("""
            [TuringStagedSpeech] authored bridge rejected
              id: \(id)
              beforeGeneratedSegmentIndex: \(beforeGeneratedSegmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              reason: playbackBoundaryAlreadyPassed
            """)
            return
        }
        guard acceptedAuthoredBridgeIDs.insert(id).inserted else {
            print("""
            [TuringStagedSpeech] duplicate authored bridge ignored
              id: \(id)
              beforeGeneratedSegmentIndex: \(beforeGeneratedSegmentIndex)
            """)
            return
        }

        let clip = AuthoredBridgeClip(
            id: id,
            fileURL: fileURL,
            beforeGeneratedSegmentIndex: beforeGeneratedSegmentIndex
        )
        pendingAuthoredBridges[
            beforeGeneratedSegmentIndex,
            default: []
        ].append(clip)
        print("""
        [TuringStagedSpeech] authored bridge queued
          id: \(id)
          file: \(fileURL.lastPathComponent)
          beforeGeneratedSegmentIndex: \(beforeGeneratedSegmentIndex)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)
        await reconcile(reason: "authoredBridgeQueued")
    }

    func setExpectedGeneratedSegmentCount(_ count: Int) async {
        guard runActive else { return }
        expectedSegmentCount = max(0, count)
        print("""
        [TuringPlaybackRebuild] expected generated count set
          expectedSegmentCount: \(expectedSegmentCount ?? 0)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)
        await reconcile(reason: "expectedGeneratedCountSet")
    }

    func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        activeComputeSegments.insert(segmentIndex)
        print("""
        [TuringPlaybackRebuild] qwen compute started
          segmentIndex: \(segmentIndex)
          activeComputeSegments: \(activeComputeSegments.sorted())
        """)
        await reconcile(reason: "computeStarted")
    }

    func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async {
        guard runActive else { return }
        activeComputeSegments.remove(segmentIndex)

        do {
            print("""
            [TuringPlaybackRebuild] qwen postprocess requested
              segmentIndex: \(segmentIndex)
              inputSampleCount: \(audio.samples.count)
              sampleRate: \(audio.sampleRate)
              channelCount: \(audio.channelCount)
              expectedLog: TuringQwenPostProcess
            """)
            let processedAudio = await TuringQwenOutputPostProcessor.processForPlayback(
                audio,
                policy: policy.outputProcessingPolicy,
                reason: "storyWalkiePlayback"
            )
            print("""
            [TuringPlaybackRebuild] qwen postprocess returned
              segmentIndex: \(segmentIndex)
              inputSampleCount: \(audio.samples.count)
              outputSampleCount: \(processedAudio.samples.count)
              sampleCountChanged: \(audio.samples.count != processedAudio.samples.count)
            """)
            guard let runID else {
                throw TuringRuntimeError.invalidConfig(
                    "Missing playback run ID while publishing segment \(segmentIndex)."
                )
            }
            let clip = try await fileStore.write(
                runID: runID,
                segmentIndex: segmentIndex,
                audio: processedAudio
            )
            pendingGenerated[segmentIndex] = clip
            if let flowIdentity {
                TuringFlowLog.event(
                    "generated segment published",
                    identity: flowIdentity,
                    fields: [
                        ("segmentIndex", String(segmentIndex)),
                        ("file", clip.fileURL.lastPathComponent)
                    ]
                )
            }
            print("""
            [TuringPlaybackRebuild] generated wav written
              segmentIndex: \(segmentIndex)
              file: \(clip.fileURL.lastPathComponent)
              frameCount: \(clip.frameCount)
              sampleRate: \(clip.sampleRate)
              pendingGenerated: \(pendingGenerated.keys.sorted())
            """)
        } catch {
            skippedSegments.insert(segmentIndex)
            print("""
            [TuringPlaybackRebuild] generated wav write failed; segment skipped
              segmentIndex: \(segmentIndex)
              error: \(error.localizedDescription)
            """)
        }

        if case .deadAir = activeItem,
           pendingGenerated[nextPlaybackSegmentIndex] != nil {
            deadAirTask?.cancel()
            deadAirTask = nil
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] dead air cancelled
              reason: generatedReady
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
        }

        await reconcile(reason: "computeFinished")
    }

    func qwenComputeSkipped(segmentIndex: Int, reason: String) async {
        guard runActive else { return }
        activeComputeSegments.remove(segmentIndex)
        skippedSegments.insert(segmentIndex)
        print("""
        [TuringPlaybackRebuild] qwen compute skipped
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
        await reconcile(reason: "computeSkipped")
    }

    func qwenComputeAllFinished() async {
        let terminalCount = expectedSegmentCount ?? inferredTerminalCount
        await sealGeneratedInput(
            finalExpectedSegmentCount: terminalCount
        )
    }

    func sealGeneratedInput(
        finalExpectedSegmentCount count: Int
    ) async {
        guard runActive else { return }
        expectedSegmentCount = max(0, count)
        allComputeFinished = true
        print("""
        [TuringStagedSpeech] input sealed
          runID: \(runID ?? "none")
          finalExpectedSegmentCount: \(expectedSegmentCount ?? 0)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          activeComputeSegments: \(activeComputeSegments.sorted())
          pendingGenerated: \(pendingGenerated.keys.sorted())
        """)
        await reconcile(reason: "generatedInputSealed")
    }

    func qwenComputeFailed(
        expectedSegmentCount count: Int,
        reason: String
    ) async {
        guard runActive else { return }

        expectedSegmentCount = max(0, count)
        let activeGeneratedIndex: Int?
        if case .generated(let segmentIndex, _, _, _) = activeItem {
            activeGeneratedIndex = segmentIndex
        } else {
            activeGeneratedIndex = nil
        }

        var newlySkipped: [Int] = []
        if count > nextPlaybackSegmentIndex {
            for index in nextPlaybackSegmentIndex..<count {
                let alreadyPrepared = pendingGenerated[index] != nil
                let currentlyPlaying = activeGeneratedIndex == index
                guard alreadyPrepared == false, currentlyPlaying == false else {
                    continue
                }
                if skippedSegments.insert(index).inserted {
                    newlySkipped.append(index)
                }
            }
        }

        activeComputeSegments.removeAll(keepingCapacity: false)
        allComputeFinished = true
        print("""
        [TuringPlaybackRebuild] qwen terminal failure reconciled
          reason: \(reason)
          expectedSegmentCount: \(count)
          newlySkippedSegments: \(newlySkipped)
          pendingGenerated: \(pendingGenerated.keys.sorted())
          activeGeneratedSegment: \(activeGeneratedIndex.map(String.init) ?? "none")
        """)
        await reconcile(reason: "computeTerminalFailure")
    }

    func waitUntilPlaybackFinished() async {
        if isFinished {
            return
        }

        await withCheckedContinuation { continuation in
            waitContinuations.append(continuation)
        }
    }

    func completedGeneratedSegmentCount() async -> Int {
        completedGeneratedPlaybackCount
    }

    func runCancelled(reason: String) async {
        guard runActive || activeItem != .none else { return }
        print("""
        [TuringPlaybackTrace] run cancellation requested
          reason: \(reason)
          activeItemBeforeCancel: \(activeItemLog)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          pendingGenerated: \(pendingGenerated.keys.sorted())
          activeComputeSegments: \(activeComputeSegments.sorted())
        """)
        runActive = false
        activeItem = .cancelled
        deadAirTask?.cancel()
        deadAirTask = nil
        await cancelActivePlayback(reason: reason)
        await endExternalGeneratedGap(
            reason: "runCancelled.\(reason)"
        )
        if let runID {
            await fileStore.endRun(runID, reason: "cancel.\(reason)")
        }
        pendingGenerated.removeAll(keepingCapacity: false)
        pendingPrerecording = nil
        pendingAuthoredBridges.removeAll(keepingCapacity: false)
        acceptedAuthoredBridgeIDs.removeAll(keepingCapacity: false)
        prerecordingHasPlayed = false
        skippedSegments.removeAll(keepingCapacity: false)
        activeComputeSegments.removeAll(keepingCapacity: false)
        print("""
        [TuringPlaybackRebuild] run cancelled
          reason: \(reason)
        """)
        resumeWaiters()
    }

    private func startEndpointEventPumpIfNeeded() async {
        guard endpointEventTask == nil else { return }
        let stream = await endpoint.events()
        endpointEventTask = Task { [weak self] in
            for await event in stream {
                guard Task.isCancelled == false else { return }
                await self?.handleEndpointEvent(event)
            }
        }
    }

    private func handleEndpointEvent(
        _ event: TuringAudioPlaybackEvent
    ) async {
        switch event {
        case .started:
            return
        case .completed(let handle, let successfully):
            await playbackCompleted(handle: handle, successfully: successfully)
        case .failed(let requestID, let eventRunID, let message):
            print("""
            [TuringAudioOffload] endpoint request failed
              requestID: \(requestID.uuidString)
              runID: \(eventRunID)
              message: \(message)
            """)
        case .cancelled(let handle, let reason):
            print("""
            [TuringAudioOffload] endpoint playback cancelled
              handleID: \(handle.id.uuidString)
              reason: \(reason)
            """)
        }
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }
        guard activeItem == .none else { return }

        while skippedSegments.remove(nextPlaybackSegmentIndex) != nil {
            print("""
            [TuringPlaybackRebuild] skipped segment advanced cursor
              segmentIndex: \(nextPlaybackSegmentIndex)
              reason: reconcile.\(reason)
            """)
            nextPlaybackSegmentIndex += 1
        }

        if prerecordingHasPlayed == false,
           let prerecording = pendingPrerecording {
            pendingPrerecording = nil
            await startPrerecording(prerecording, reason: reason)
            return
        }
        if prerecordingHasPlayed == false,
           prerecordingExpected {
            return
        }

        if var bridges =
                pendingAuthoredBridges[nextPlaybackSegmentIndex],
           bridges.isEmpty == false {
            let bridge = bridges.removeFirst()
            if bridges.isEmpty {
                pendingAuthoredBridges.removeValue(
                    forKey: nextPlaybackSegmentIndex
                )
            } else {
                pendingAuthoredBridges[nextPlaybackSegmentIndex] = bridges
            }
            await startAuthoredBridge(bridge, reason: reason)
            return
        }

        if firstPrerollRemaining > 0,
           pendingGenerated[nextPlaybackSegmentIndex] != nil {
            firstPrerollRemaining -= 1
            await startFiller(reason: "firstSegmentPreroll.generatedReady")
            return
        }

        if isPrerecordingToInitialGeneratedBridgeWaiting {
            if firstPrerollRemaining > 0 {
                firstPrerollRemaining -= 1
            }
            await startFiller(
                reason: "prerecordingToFirstGenerated.computeBridge"
            )
            return
        }

        if let clip = pendingGenerated.removeValue(forKey: nextPlaybackSegmentIndex) {
            await startGenerated(clip, reason: reason)
            return
        }

        if isFinished {
            await finishRun(reason: "allDone")
            return
        }

        if allComputeFinished == false,
           let bridge =
                policy.externalGeneratedGapBridge,
           let runID {
            await bridge.beginGap(
                ownerID: runID,
                waitingForSegmentIndex:
                    nextPlaybackSegmentIndex,
                reason:
                    "waitingForExactGenerated.\(reason)"
            )
            print("""
            [TuringPlaybackRebuild] external gap bridge
              runID: \(runID)
              waitingForSegmentIndex: \(nextPlaybackSegmentIndex)
              bridgeType: \(String(reflecting: type(of: bridge)))
            """)
            return
        }

        if allComputeFinished == false,
           policy.chainFillerWhileComputeWithoutSpeech {
            if shouldUseDeadAirWhileWaitingForInitialGeneratedSegment {
                if policy.deadAirAfterFillerEnabled {
                    print("""
                    [TuringPlaybackRebuild] compute filler suppressed before first generated segment
                      reason: \(reason)
                      nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
                      firstPrerollRemaining: \(firstPrerollRemaining)
                      activeComputeSegments: \(activeComputeSegments.sorted())
                      bridge: deadAirOnly
                    """)
                    startDeadAir(reason: "initialGeneratedSegmentWaiting.\(reason)")
                }
                return
            }
            await startFiller(reason: "computeWithoutSpeech")
            return
        }

        if isFinished {
            await finishRun(reason: "allDone")
        }
    }

    private func playOneShot(
        fileURL: URL,
        kind: TuringAudioClipKind,
        label: String
    ) async throws -> TuringAudioPlaybackHandle {
        guard let runID else {
            throw TuringRuntimeError.invalidConfig("Missing active playback run ID.")
        }
        let gainDB: Float
        switch kind {
        case .generated:
            gainDB = policy.generatedGainDB
        case .prerecording:
            gainDB = policy.prerecordingGainDB
        case .filler:
            gainDB = policy.fillerGainDB
        case .commSFX, .ambientStatic, .sendingStatic,
             .radioCue, .radioBroadcast,
             .crankRadioTuningFiller,
             .hamReceiverAmbient,
             .hamReceiverTuningFiller:
            gainDB = 0
        }
        let route: TuringAudioRouteID
        switch policy.voiceRoute {
        case .walkieSpatial:
            route = .storyWalkie
        case .playerGlobal:
            route = .richGlobal
        case .playerHeadTracked:
            route = .richHeadTracked
        case .crankRadioSpatial:
            route = .rollingBenchRadio
        case .hamReceiverSpatial:
            route = .hamReceiver
        }
        return try await endpoint.play(
            TuringAudioPlaybackRequest(
                requestID: UUID(),
                runID: runID,
                fileURL: fileURL,
                kind: kind,
                route: route,
                label: label,
                gainDB: gainDB,
                shouldLoop: false,
                cachePolicy: kind == .generated ? .transient : .bundled
            )
        )
    }

    private func cancelActivePlayback(reason: String) async {
        guard let handle = activeItem.handle else {
            return
        }
        await endpoint.stop(handle, reason: reason)
    }

    private var voiceEmitterLogName: String {
        switch policy.voiceRoute {
        case .walkieSpatial:
            return "TuringStoryWalkieTalkie_AudioEmitter"
        case .playerGlobal:
            return "none"
        case .playerHeadTracked:
            return "TuringRichHeadset_AudioEmitter"
        case .crankRadioSpatial:
            return "TuringRollingBenchCrankRadio_AudioEmitter"
        case .hamReceiverSpatial:
            return "TuringRollingBenchHamReceiver_AudioEmitter"
        }
    }

    private var completionSourceLogName: String {
        switch policy.voiceRoute {
        case .walkieSpatial:
            return "AudioPlaybackController.completionHandler"
        case .playerGlobal:
            return "AVAudioPlayerDelegate.audioPlayerDidFinishPlaying"
        case .playerHeadTracked:
            return "AudioPlaybackController.completionHandler"
        case .crankRadioSpatial:
            return "AudioPlaybackController.completionHandler"
        case .hamReceiverSpatial:
            return "AudioPlaybackController.completionHandler"
        }
    }

    private func startPrerecording(
        _ clip: PrerecordingClip,
        reason: String
    ) async {
        guard activeItem == .none else {
            pendingPrerecording = clip
            return
        }
        do {
            await endExternalGeneratedGap(
                reason:
                    "prerecordingStarting.\(clip.id).\(reason)"
            )
            print("""
            [TuringPlaybackTrace] prerecording playback request
              id: \(clip.id)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingGenerated: \(pendingGenerated.keys.sorted())
            """)
            let handle = try await playOneShot(
                fileURL: clip.fileURL,
                kind: .prerecording,
                label: clip.id
            )
            activeItem = .prerecording(
                id: clip.id,
                handle: handle,
                fileURL: clip.fileURL,
                startedAt: Date()
            )
            if let flowIdentity {
                TuringFlowLog.event(
                    "prerecording playback started",
                    identity: flowIdentity,
                    fields: [
                        ("prerecordingPlaybackHandleID", handle.id.uuidString),
                        ("file", clip.fileURL.lastPathComponent)
                    ]
                )
            }
            print("""
            [TuringPlaybackRebuild] prerecording playback started
              id: \(clip.id)
              handleID: \(handle.id.uuidString)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              voiceRoute: \(policy.voiceRoute.rawValue)
              spatialEmitter: \(voiceEmitterLogName)
              completionSource: \(completionSourceLogName)
              completionGate: coordinatorActiveHandleMatch
            """)
        } catch {
            print("""
            [TuringPlaybackRebuild] prerecording playback failed
              id: \(clip.id)
              file: \(clip.fileURL.lastPathComponent)
              error: \(error.localizedDescription)
            """)
            await runCancelled(reason: "prerecordingStartFailed.\(clip.id)")
        }
    }

    private func startAuthoredBridge(
        _ clip: AuthoredBridgeClip,
        reason: String
    ) async {
        guard activeItem == .none else {
            pendingAuthoredBridges[
                clip.beforeGeneratedSegmentIndex,
                default: []
            ].insert(clip, at: 0)
            return
        }
        do {
            print("""
            [TuringPlaybackTrace] authored bridge playback request
              id: \(clip.id)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              beforeGeneratedSegmentIndex: \(clip.beforeGeneratedSegmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            let handle = try await playOneShot(
                fileURL: clip.fileURL,
                kind: .prerecording,
                label: clip.id
            )
            activeItem = .authoredBridge(
                id: clip.id,
                beforeGeneratedSegmentIndex:
                    clip.beforeGeneratedSegmentIndex,
                handle: handle,
                fileURL: clip.fileURL,
                startedAt: Date()
            )
            print("""
            [TuringStagedSpeech] authored bridge playback started
              id: \(clip.id)
              handleID: \(handle.id.uuidString)
              file: \(clip.fileURL.lastPathComponent)
              beforeGeneratedSegmentIndex: \(clip.beforeGeneratedSegmentIndex)
              voiceRoute: \(policy.voiceRoute.rawValue)
              completionSource: \(completionSourceLogName)
            """)
        } catch {
            print("""
            [TuringStagedSpeech] authored bridge playback failed
              id: \(clip.id)
              file: \(clip.fileURL.lastPathComponent)
              error: \(error.localizedDescription)
            """)
            await runCancelled(
                reason: "authoredBridgeStartFailed.\(clip.id)"
            )
        }
    }

    private func startGenerated(_ clip: GeneratedClip, reason: String) async {
        guard activeItem == .none else {
            pendingGenerated[clip.segmentIndex] = clip
            return
        }
        do {
            await endExternalGeneratedGap(
                reason:
                    "generatedReady.\(clip.segmentIndex).\(reason)"
            )
            if clip.segmentIndex == 0,
               policy.stopSendingStaticBeforeGeneratedSegmentZero {
                await TuringWalkieCommsFXController.shared
                    .stopSendingLeadIn(
                        reason:
                            "incomingGeneratedSegmentZero.\(runID ?? "unknownRun")"
                    )
                print("""
                [TuringPlaybackRebuild] sending static cutoff reached
                  runID: \(runID ?? "unknownRun")
                  segmentIndex: \(clip.segmentIndex)
                  stopped: sending-static-loop.mp3
                  ambientStaticContinues: true
                  boundary: incomingBigMikeGeneratedPlaybackStart
                """)
            }
            print("""
            [TuringPlaybackTrace] generated playback request
              segmentIndex: \(clip.segmentIndex)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              frameCount: \(clip.frameCount)
              sampleRate: \(clip.sampleRate)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingGenerated: \(pendingGenerated.keys.sorted())
            """)
            let handle = try await playOneShot(
                fileURL: clip.fileURL,
                kind: .generated,
                label: String(format: "segment_%04d", clip.segmentIndex)
            )
            let startedAt = Date()
            activeItem = .generated(
                segmentIndex: clip.segmentIndex,
                handle: handle,
                fileURL: clip.fileURL,
                startedAt: startedAt
            )
            if let flowIdentity {
                TuringFlowLog.event(
                    "generated playback started",
                    identity: flowIdentity,
                    fields: [
                        ("segmentIndex", String(clip.segmentIndex)),
                        ("generatedPlaybackHandleID", handle.id.uuidString),
                        ("file", clip.fileURL.lastPathComponent)
                    ]
                )
            }
            print("""
            [TuringPlaybackRebuild] generated playback started
              segmentIndex: \(clip.segmentIndex)
              handleID: \(handle.id.uuidString)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              voiceRoute: \(policy.voiceRoute.rawValue)
              spatialEmitter: \(voiceEmitterLogName)
              completionSource: \(completionSourceLogName)
              completionGate: coordinatorActiveHandleMatch
            """)
        } catch {
            skippedSegments.insert(clip.segmentIndex)
            await fileStore.delete(clip, reason: "generatedStartFailed")
            print("""
            [TuringPlaybackRebuild] generated playback failed; segment skipped
              segmentIndex: \(clip.segmentIndex)
              error: \(error.localizedDescription)
            """)
            await reconcile(reason: "generatedStartFailed")
        }
    }

    private func startFiller(reason: String) async {
        guard activeItem == .none else { return }
        guard let fillerURL = nextFillerURL() else {
            if policy.deadAirAfterFillerEnabled {
                startDeadAir(reason: "missingFiller.\(reason)")
            }
            return
        }
        do {
            print("""
            [TuringPlaybackTrace] filler playback request
              reason: \(reason)
              clip: \(fillerURL.lastPathComponent)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingNextReady: \(pendingGenerated[nextPlaybackSegmentIndex] != nil)
            """)
            let handle = try await playOneShot(
                fileURL: fillerURL,
                kind: .filler,
                label: fillerURL.deletingPathExtension().lastPathComponent
            )
            lastFillerURL = fillerURL
            activeItem = .filler(
                handle: handle,
                fileURL: fillerURL,
                startedAt: Date()
            )
            print("""
            [TuringPlaybackRebuild] filler started
              reason: \(reason)
              clip: \(fillerURL.lastPathComponent)
              handleID: \(handle.id.uuidString)
              voiceRoute: \(policy.voiceRoute.rawValue)
              spatialEmitter: \(voiceEmitterLogName)
              completionSource: \(completionSourceLogName)
            """)
        } catch {
            print("""
            [TuringPlaybackRebuild] filler start failed
              reason: \(reason)
              clip: \(fillerURL.lastPathComponent)
              error: \(error.localizedDescription)
            """)
            if policy.deadAirAfterFillerEnabled {
                startDeadAir(reason: "fillerStartFailed")
            }
        }
    }

    private func startDeadAir(reason: String) {
        guard activeItem == .none else { return }
        let minimum = min(policy.deadAirMinSeconds, policy.deadAirMaxSeconds)
        let maximum = max(policy.deadAirMinSeconds, policy.deadAirMaxSeconds)
        let seconds = Double.random(in: minimum...maximum)
        let id = UUID()
        activeItem = .deadAir(id: id)
        print("""
        [TuringPlaybackRebuild] dead air started
          id: \(id.uuidString)
          reason: \(reason)
          seconds: \(String(format: "%.2f", seconds))
        """)
        let deadAirNanoseconds = UInt64(seconds * 1_000_000_000)
        deadAirTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: deadAirNanoseconds)
            await self?.deadAirFinished(id: id)
        }
    }

    private func deadAirFinished(id: UUID) async {
        guard activeItem == .deadAir(id: id) else { return }
        activeItem = .none
        deadAirTask = nil
        print("""
        [TuringPlaybackRebuild] dead air finished
          id: \(id.uuidString)
        """)
        await reconcile(reason: "deadAirFinished")
    }

    private func playbackCompleted(
        handle: TuringAudioPlaybackHandle,
        successfully: Bool
    ) async {
        print("""
        [TuringPlaybackTrace] coordinator completion received
          handleID: \(handle.id.uuidString)
          successfully: \(successfully)
          activeItemBeforeMatch: \(activeItemLog)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          pendingGenerated: \(pendingGenerated.keys.sorted())
        """)

        guard successfully else {
            print("""
            [TuringPlaybackRebuild] playback completion rejected
              handleID: \(handle.id.uuidString)
              activeItem: \(activeItemLog)
              reason: playbackBackendReportedFailure
            """)
            await runCancelled(
                reason: "playbackBackendFailure.\(handle.id.uuidString)"
            )
            return
        }

        switch activeItem {
        case .prerecording(
            let id,
            let activeHandle,
            let fileURL,
            let startedAt
        )
            where activeHandle == handle:
            prerecordingHasPlayed = true
            activeItem = .none
            if let flowIdentity {
                TuringFlowLog.event(
                    "prerecording playback completed",
                    identity: flowIdentity,
                    fields: [
                        ("prerecordingPlaybackHandleID", handle.id.uuidString),
                        ("file", fileURL.lastPathComponent)
                    ]
                )
            }
            print("""
            [TuringPlaybackRebuild] prerecording playback completed
              id: \(id)
              handleID: \(handle.id.uuidString)
              file: \(fileURL.lastPathComponent)
              elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(startedAt)))
              completionSource: \(completionSourceLogName)
              fillerBridgeRequired: \(policy.chainFillerFromPrerecordingToFirstGenerated)
              firstPrerollRemaining: \(firstPrerollRemaining)
            """)
            await reconcile(reason: "prerecordingCompleted")

        case .authoredBridge(
            let id,
            let beforeGeneratedSegmentIndex,
            let activeHandle,
            let fileURL,
            let startedAt
        )
            where activeHandle == handle:
            activeItem = .none
            print("""
            [TuringStagedSpeech] authored bridge playback completed
              id: \(id)
              handleID: \(handle.id.uuidString)
              file: \(fileURL.lastPathComponent)
              elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(startedAt)))
              beforeGeneratedSegmentIndex: \(beforeGeneratedSegmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              completionSource: \(completionSourceLogName)
            """)
            await reconcile(reason: "authoredBridgeCompleted")

        case .generated(
            let segmentIndex,
            let activeHandle,
            let fileURL,
            let startedAt
        )
            where activeHandle == handle:
            let elapsed = Date().timeIntervalSince(startedAt)
            print("""
            [TuringPlaybackTrace] generated completion accepted
              segmentIndex: \(segmentIndex)
              handleID: \(handle.id.uuidString)
              elapsedSeconds: \(String(format: "%.3f", elapsed))
              willAdvanceToSegmentIndex: \(segmentIndex + 1)
            """)
            nextPlaybackSegmentIndex = segmentIndex + 1
            completedGeneratedPlaybackCount += 1
            activeItem = .none
            if let flowIdentity {
                TuringFlowLog.event(
                    "generated playback completed",
                    identity: flowIdentity,
                    fields: [
                        ("segmentIndex", String(segmentIndex)),
                        ("generatedPlaybackHandleID", handle.id.uuidString),
                        ("file", fileURL.lastPathComponent)
                    ]
                )
            }
            print("""
            [TuringPlaybackRebuild] generated playback completed
              segmentIndex: \(segmentIndex)
              handleID: \(handle.id.uuidString)
              completionSource: \(completionSourceLogName)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            if let spatial = endpoint as? TuringSpatialAudioEndpoint {
                await spatial.evictTransient(fileURL: fileURL)
            }
            await fileStore.delete(
                fileURL: fileURL,
                runID: handle.runID,
                segmentIndex: segmentIndex,
                reason: "generatedPlaybackCompleted"
            )
            await reconcile(reason: "generatedCompleted")

        case .filler(
            let activeHandle,
            let fileURL,
            let startedAt
        )
            where activeHandle == handle:
            let elapsed = Date().timeIntervalSince(startedAt)
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] filler completed
              handleID: \(handle.id.uuidString)
              clip: \(fileURL.lastPathComponent)
              elapsedSeconds: \(String(format: "%.3f", elapsed))
              pendingNextReady: \(pendingGenerated[nextPlaybackSegmentIndex] != nil)
            """)
            if isPrerecordingToInitialGeneratedBridgeWaiting {
                if policy.deadAirAfterFillerEnabled {
                    startDeadAir(
                        reason: "prerecordingToFirstGenerated.afterFiller"
                    )
                    return
                }
                await reconcile(
                    reason: "prerecordingToFirstGenerated.fillerCompleted"
                )
                return
            }
            if pendingGenerated[nextPlaybackSegmentIndex] == nil,
               allComputeFinished == false,
               policy.deadAirAfterFillerEnabled {
                startDeadAir(reason: "afterFiller")
                return
            }
            await reconcile(reason: "fillerCompleted")

        default:
            print("""
            [TuringPlaybackRebuild] stale playback completion ignored
              handleID: \(handle.id.uuidString)
              activeItem: \(activeItemLog)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingGenerated: \(pendingGenerated.keys.sorted())
            """)
        }
    }

    private var isFinished: Bool {
        guard runActive else { return true }
        if let expectedSegmentCount,
           nextPlaybackSegmentIndex < expectedSegmentCount {
            return false
        }
        return allComputeFinished &&
            activeComputeSegments.isEmpty &&
            pendingGenerated.isEmpty &&
            pendingAuthoredBridges.isEmpty &&
            skippedSegments.isEmpty &&
            activeItem == .none
    }

    private var inferredTerminalCount: Int {
        var count = nextPlaybackSegmentIndex
        if let maximum = activeComputeSegments.max() {
            count = max(count, maximum + 1)
        }
        if let maximum = pendingGenerated.keys.max() {
            count = max(count, maximum + 1)
        }
        if let maximum = skippedSegments.max() {
            count = max(count, maximum + 1)
        }
        if case .generated(let segmentIndex, _, _, _) = activeItem {
            count = max(count, segmentIndex + 1)
        }
        return count
    }

    private var shouldUseDeadAirWhileWaitingForInitialGeneratedSegment: Bool {
        nextPlaybackSegmentIndex == 0 && pendingGenerated[0] == nil
    }

    private var isPrerecordingToInitialGeneratedBridgeWaiting: Bool {
        guard policy.chainFillerFromPrerecordingToFirstGenerated,
              prerecordingHasPlayed,
              nextPlaybackSegmentIndex == 0,
              pendingGenerated[0] == nil,
              allComputeFinished == false else {
            return false
        }

        if let expectedSegmentCount {
            return expectedSegmentCount > 0
        }
        return true
    }

    private func finishRun(reason: String) async {
        guard runActive else { return }
        await endExternalGeneratedGap(
            reason: "runFinished.\(reason)"
        )
        runActive = false
        if let runID {
            await fileStore.endRun(runID, reason: "finish.\(reason)")
        }
        print("""
        [TuringPlaybackRebuild] run finished
          runID: \(runID ?? "nil")
          reason: \(reason)
        """)
        resumeWaiters()
    }

    private func endExternalGeneratedGap(
        reason: String
    ) async {
        guard let bridge =
                policy.externalGeneratedGapBridge,
              let runID else {
            return
        }
        await bridge.endGap(
            ownerID: runID,
            reason: reason
        )
    }

    private func resumeWaiters() {
        let continuations = waitContinuations
        waitContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func nextFillerURL() -> URL? {
        guard fillerFiles.isEmpty == false else { return nil }
        if policy.avoidImmediateFillerRepeat,
           fillerFiles.count > 1 {
            let candidates = fillerFiles.filter { $0 != lastFillerURL }
            return candidates.randomElement()
        }
        return fillerFiles.randomElement()
    }

    private var activeItemLog: String {
        switch activeItem {
        case .none:
            return "none"
        case .generated(
            let segmentIndex,
            let handle,
            _,
            let startedAt
        ):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "generated.\(segmentIndex).\(handle.id.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .prerecording(let id, let handle, let fileURL, let startedAt):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "prerecording.\(id).\(fileURL.lastPathComponent).\(handle.id.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .authoredBridge(
            let id,
            let beforeGeneratedSegmentIndex,
            let handle,
            let fileURL,
            let startedAt
        ):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "authoredBridge.\(id).before=\(beforeGeneratedSegmentIndex).\(fileURL.lastPathComponent).\(handle.id.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .filler(let handle, let fileURL, let startedAt):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "filler.\(fileURL.lastPathComponent).\(handle.id.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .deadAir(let id):
            return "deadAir.\(id.uuidString)"
        case .cancelled:
            return "cancelled"
        }
    }

    private static func formatSeconds(_ seconds: Double?) -> String {
        guard let seconds else {
            return "nil"
        }
        return String(format: "%.3f", seconds)
    }
}
