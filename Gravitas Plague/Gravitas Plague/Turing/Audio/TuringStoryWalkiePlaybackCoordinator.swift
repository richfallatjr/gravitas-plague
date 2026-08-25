import AVFoundation
import Foundation

actor TuringStoryWalkiePlaybackCoordinator: TuringSpokenCoverControlling {
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
        var prerecordingGainDB: Float = 0
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

    private struct AuthoredBridgeClip: Equatable {
        let item: TuringAuthoredMediaItem
        let beforeGeneratedSegmentIndex: Int

        var id: String { item.id }
        var fileURL: URL { item.fileURL }
    }

    private enum ActiveItem: Equatable {
        case none
        case startingAuthored(
            clip: AuthoredBridgeClip,
            requestID: UUID
        )
        case orientingAuthored(clip: AuthoredBridgeClip)
        case prerecording(
            id: String,
            handle: TuringAudioPlaybackHandle,
            fileURL: URL,
            startedAt: Date
        )
        case authoredBridge(
            clip: AuthoredBridgeClip,
            handle: TuringAudioPlaybackHandle,
            fileURL: URL,
            startedAt: Date
        )
        case startingGenerated(
            segmentIndex: Int,
            requestID: UUID,
            fileURL: URL
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
                 .authoredBridge(_, let handle, _, _),
                 .generated(_, let handle, _, _),
                 .filler(let handle, _, _):
                return handle
            case .none, .startingAuthored, .orientingAuthored,
                 .startingGenerated,
                 .deadAir, .cancelled:
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
    private var authoredOnlyRun = false
    private var authoredInputSealed = false
    private var authoredFailureReason: String?
    private let lifecycleHub = TuringFlowPlaybackLifecycleHub()
    private weak var playbackLifecycleSink:
        (any TuringFlowPlaybackLifecycleSink)?
    private var authoredProgressionHolds:
        [UUID: TuringAuthoredProgressionHoldToken] = [:]
    private var currentItemBoundaryWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var pausedSpokenReceipts:
        [UUID: TuringSpokenCoverPauseReceipt] = [:]
    private var generatedPlaybackConfiguration:
        TuringGeneratedPlaybackConfiguration = .routeDefault

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

    func configureGeneratedPlayback(
        _ configuration: TuringGeneratedPlaybackConfiguration
    ) async {
        generatedPlaybackConfiguration = configuration
    }

    func generatedPlaybackGateDidChange() async {
        await reconcile(reason: "generatedPlaybackGateChanged")
    }

    func beginRun(runID: String, expectedSegmentCount: Int?) async {
        await runCancelled(reason: "beginNewRun")

        await startEndpointEventPumpIfNeeded()

        self.runID = runID
        self.authoredOnlyRun = false
        self.authoredInputSealed = false
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
        self.authoredProgressionHolds.removeAll(keepingCapacity: false)
        self.pausedSpokenReceipts.removeAll(keepingCapacity: false)
        resumeCurrentItemBoundaryWaiters()

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

    func beginAuthoredRun(identity: TuringFlowIdentity) async {
        await runCancelled(reason: "beginNewAuthoredRun")
        await startEndpointEventPumpIfNeeded()

        flowIdentity = identity
        runID = identity.playbackRunID
        acceptedPrerecordingID = nil
        expectedSegmentCount = 0
        nextPlaybackSegmentIndex = 0
        completedGeneratedPlaybackCount = 0
        activeComputeSegments.removeAll(keepingCapacity: false)
        pendingGenerated.removeAll(keepingCapacity: false)
        pendingPrerecording = nil
        pendingAuthoredBridges.removeAll(keepingCapacity: false)
        acceptedAuthoredBridgeIDs.removeAll(keepingCapacity: false)
        prerecordingExpected = false
        prerecordingHasPlayed = true
        skippedSegments.removeAll(keepingCapacity: false)
        allComputeFinished = true
        activeItem = .none
        firstPrerollRemaining = 0
        deadAirTask?.cancel()
        deadAirTask = nil
        fillerFiles = []
        authoredOnlyRun = true
        authoredInputSealed = false
        authoredFailureReason = nil
        authoredProgressionHolds.removeAll(keepingCapacity: false)
        pausedSpokenReceipts.removeAll(keepingCapacity: false)
        resumeCurrentItemBoundaryWaiters()
        runActive = true

        print("""
        [StoryPlayMode] authored playback run opened
          runID: \(identity.playbackRunID)
          scriptPointID: \(identity.scriptPointID)
          generatedFileStoreOpened: false
          fillerCatalogLoaded: false
        """)
    }

    func enqueueAuthoredMedia(_ item: TuringAuthoredMediaItem) async throws {
        guard runActive, authoredOnlyRun, authoredInputSealed == false else {
            throw TuringRuntimeError.invalidConfig(
                "Authored media was submitted outside an open authored run."
            )
        }
        guard acceptedAuthoredBridgeIDs.insert(item.id).inserted else {
            throw TuringRuntimeError.invalidConfig(
                "Duplicate authored media item \(item.id)."
            )
        }
        pendingAuthoredBridges[0, default: []].append(
            AuthoredBridgeClip(
                item: item,
                beforeGeneratedSegmentIndex: 0
            )
        )
        print("[StoryPlayMode] authored media queued id=\(item.id) role=\(item.role.rawValue) file=\(item.fileURL.lastPathComponent)")
        await reconcile(reason: "authoredMediaQueued")
    }

    func sealAuthoredInput() async {
        guard runActive, authoredOnlyRun else { return }
        authoredInputSealed = true
        await reconcile(reason: "authoredInputSealed")
    }

    func waitUntilAuthoredPlaybackFinished() async throws {
        await waitUntilPlaybackFinished()
        if let authoredFailureReason {
            throw TuringRuntimeError.invalidConfig(
                "Authored playback failed: \(authoredFailureReason)"
            )
        }
    }

    func lifecycleEvents() async -> AsyncStream<TuringFlowPlaybackLifecycleEvent> {
        await lifecycleHub.stream()
    }

    func setPlaybackLifecycleSink(
        _ sink: (any TuringFlowPlaybackLifecycleSink)?
    ) async {
        playbackLifecycleSink = sink
    }

    func acquireAuthoredProgressionHold(
        liveSessionID: UUID,
        reason: String
    ) async throws -> TuringAuthoredProgressionHoldToken {
        guard runActive, authoredOnlyRun, let runID else {
            throw TuringRuntimeError.invalidConfig(
                "Authored progression hold requires an active authored run."
            )
        }
        let token = TuringAuthoredProgressionHoldToken(
            id: UUID(),
            playbackRunID: runID,
            liveSessionID: liveSessionID
        )
        authoredProgressionHolds[token.id] = token
        print("[TuringLiveConversation] progression hold acquired token=\(token.id.uuidString) runID=\(runID) reason=\(reason)")
        return token
    }

    func releaseAuthoredProgressionHold(
        _ token: TuringAuthoredProgressionHoldToken,
        reason: String
    ) async throws {
        guard let stored = authoredProgressionHolds.removeValue(forKey: token.id),
              stored == token,
              token.playbackRunID == runID else {
            throw TuringRuntimeError.invalidConfig(
                "Authored progression hold token is stale."
            )
        }
        print("[TuringLiveConversation] progression hold released token=\(token.id.uuidString) reason=\(reason)")
        await reconcile(reason: "progressionHoldReleased")
    }

    func waitUntilCurrentSpokenItemCompletes(
        hold: TuringAuthoredProgressionHoldToken
    ) async throws {
        guard authoredProgressionHolds[hold.id] == hold else {
            throw TuringRuntimeError.invalidConfig(
                "Authored progression hold token is stale."
            )
        }
        if activeItem.handle == nil,
           pausedSpokenReceipts.values.contains(where: { $0.handle != nil }) == false {
            return
        }
        await withCheckedContinuation { continuation in
            currentItemBoundaryWaiters.append(continuation)
        }
    }

    func pauseCurrentSpokenMedia(
        interruptionID: UUID
    ) async throws -> TuringSpokenCoverPauseReceipt {
        guard let runID else {
            throw TuringRuntimeError.invalidConfig(
                "Spoken cover has no active playback run."
            )
        }

        let itemIdentity: String
        let handle: TuringAudioPlaybackHandle
        let authoredItemID: String?
        switch activeItem {
        case .authoredBridge(let clip, let activeHandle, _, _):
            guard clip.item.liveConversationCatalogEntry != nil else {
                throw TuringRuntimeError.invalidConfig(
                    "The current authored item is not conversation eligible."
                )
            }
            itemIdentity = clip.id
            authoredItemID = clip.id
            handle = activeHandle
        case .generated(let segmentIndex, let activeHandle, _, _):
            itemIdentity = "generated.\(segmentIndex)"
            authoredItemID = nil
            handle = activeHandle
        case .none, .startingAuthored, .orientingAuthored,
             .startingGenerated, .filler, .deadAir:
            return TuringSpokenCoverPauseReceipt(
                interruptionID: interruptionID,
                playbackRunID: runID,
                itemIdentity: "prerecordingPreFiller",
                handle: nil,
                result: .completedBeforePause
            )
        case .cancelled:
            throw TuringRuntimeError.invalidConfig(
                "The spoken cover playback run was cancelled."
            )
        case .prerecording:
            throw TuringRuntimeError.invalidConfig(
                "There is no active spoken media to pause."
            )
        }

        let receipt = TuringSpokenCoverPauseReceipt(
            interruptionID: interruptionID,
            playbackRunID: runID,
            itemIdentity: itemIdentity,
            handle: handle,
            result: .paused
        )
        pausedSpokenReceipts[interruptionID] = receipt
        do {
            try await endpoint.pause(
                handle,
                reason: "liveConversation.\(interruptionID.uuidString)"
            )
        } catch {
            if activeItem.handle != handle {
                pausedSpokenReceipts.removeValue(forKey: interruptionID)
                return TuringSpokenCoverPauseReceipt(
                    interruptionID: interruptionID,
                    playbackRunID: runID,
                    itemIdentity: itemIdentity,
                    handle: nil,
                    result: .completedBeforePause
                )
            }
            pausedSpokenReceipts.removeValue(forKey: interruptionID)
            throw error
        }

        if let authoredItemID {
            await emitLifecycleEvent(
                .authoredMediaPaused(
                    runID: runID,
                    itemID: authoredItemID,
                    handle: handle,
                    interruptionID: interruptionID
                )
            )
        }
        return receipt
    }

    func resumeCurrentSpokenMedia(
        _ receipt: TuringSpokenCoverPauseReceipt
    ) async throws {
        guard receipt.playbackRunID == runID else {
            throw TuringRuntimeError.invalidConfig(
                "Spoken cover pause receipt belongs to another run."
            )
        }
        guard receipt.result == .paused,
              let handle = receipt.handle else {
            return
        }
        guard pausedSpokenReceipts.removeValue(
            forKey: receipt.interruptionID
        ) != nil else {
            return
        }
        guard activeItem.handle == handle else {
            return
        }
        try await endpoint.resume(
            handle,
            reason: "liveConversation.\(receipt.interruptionID.uuidString)"
        )
        if case .authoredBridge(let clip, _, _, _) = activeItem {
            await emitLifecycleEvent(
                .authoredMediaResumed(
                    runID: handle.runID,
                    itemID: clip.id,
                    handle: handle,
                    interruptionID: receipt.interruptionID
                )
            )
        }
    }

    func waitUntilSpokenMediaCompletes(
        _ receipt: TuringSpokenCoverPauseReceipt
    ) async throws {
        guard receipt.playbackRunID == runID else {
            throw TuringRuntimeError.invalidConfig(
                "Spoken cover pause receipt belongs to another run."
            )
        }
        if receipt.itemIdentity.hasPrefix("generated.") {
            await waitUntilPlaybackFinished()
            return
        }
        guard let handle = receipt.handle else {
            return
        }
        if activeItem.handle != handle {
            return
        }
        await withCheckedContinuation { continuation in
            currentItemBoundaryWaiters.append(continuation)
        }
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
            item: TuringAuthoredMediaItem(
                scriptPointID: flowIdentity?.scriptPointID ?? "unknown",
                id: id,
                role: .authoredBridge,
                fileURL: fileURL
            ),
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
        let wasAuthoredOnlyRun = authoredOnlyRun
        if wasAuthoredOnlyRun {
            authoredFailureReason = reason
        }
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
        if let runID, wasAuthoredOnlyRun == false {
            await fileStore.endRun(runID, reason: "cancel.\(reason)")
        }
        pendingGenerated.removeAll(keepingCapacity: false)
        pendingPrerecording = nil
        pendingAuthoredBridges.removeAll(keepingCapacity: false)
        acceptedAuthoredBridgeIDs.removeAll(keepingCapacity: false)
        prerecordingHasPlayed = false
        skippedSegments.removeAll(keepingCapacity: false)
        activeComputeSegments.removeAll(keepingCapacity: false)
        authoredProgressionHolds.removeAll(keepingCapacity: false)
        pausedSpokenReceipts.removeAll(keepingCapacity: false)
        resumeCurrentItemBoundaryWaiters()
        authoredOnlyRun = false
        authoredInputSealed = false
        print("""
        [TuringPlaybackRebuild] run cancelled
          reason: \(reason)
        """)
        if let runID {
            await emitLifecycleEvent(.failed(runID: runID, reason: reason))
        }
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
        case .started(let handle):
            await playbackStarted(handle)
        case .paused(let handle, let reason):
            print("[TuringAudioOffload] endpoint playback paused handleID=\(handle.id.uuidString) reason=\(reason)")
        case .resumed(let handle, let reason):
            print("[TuringAudioOffload] endpoint playback resumed handleID=\(handle.id.uuidString) reason=\(reason)")
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

        if authoredOnlyRun,
           authoredProgressionHolds.isEmpty == false {
            resumeCurrentItemBoundaryWaiters()
            return
        }

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

        if let clip = pendingGenerated[nextPlaybackSegmentIndex] {
            if let gate = generatedPlaybackConfiguration.startGate {
                switch await gate.currentState() {
                case .closed:
                    return
                case .cancelled(let message):
                    await runCancelled(reason: "generatedGateCancelled.\(message)")
                    return
                case .open:
                    break
                }
            }
            pendingGenerated.removeValue(forKey: nextPlaybackSegmentIndex)
            await startGenerated(clip, reason: reason)
            return
        }

        if isFinished {
            await finishRun(reason: "allDone")
            return
        }

        if allComputeFinished == false,
           nextPlaybackSegmentIndex == 0,
           generatedPlaybackConfiguration.initialGapOwnership == .externallyOwned {
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

    private func playbackStarted(
        _ handle: TuringAudioPlaybackHandle
    ) async {
        guard handle.runID == runID else { return }
        switch activeItem {
        case .startingAuthored(let clip, let requestID)
            where requestID == handle.requestID:
            activeItem = .authoredBridge(
                clip: clip,
                handle: handle,
                fileURL: clip.fileURL,
                startedAt: Date()
            )
            await emitLifecycleEvent(
                .authoredMediaStarted(
                    runID: handle.runID,
                    item: clip.item,
                    handle: handle
                )
            )
            print("[TuringPlaybackLifecycle] authored actual start id=\(clip.id) handleID=\(handle.id.uuidString)")

        case .startingGenerated(let segmentIndex, let requestID, let fileURL)
            where requestID == handle.requestID:
            activeItem = .generated(
                segmentIndex: segmentIndex,
                handle: handle,
                fileURL: fileURL,
                startedAt: Date()
            )
            await emitLifecycleEvent(
                .generatedSegmentStarted(
                    runID: handle.runID,
                    segmentIndex: segmentIndex,
                    handle: handle
                )
            )

        default:
            break
        }
    }

    private func playOneShot(
        requestID: UUID = UUID(),
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
             .hamReceiverTuningFiller,
             .storyRobotSpeech:
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
                requestID: requestID,
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
            if clip.item.orientationMode == .playbackOwnedBridge {
                guard let flowIdentity else {
                    throw TuringRuntimeError.invalidConfig(
                        "Authored bridge orientation requires a flow identity."
                    )
                }
                activeItem = .orientingAuthored(clip: clip)
                let descriptor = try TuringFlowDescriptorStore().require(
                    clip.item.scriptPointID
                )
                _ = try await TuringPrerecordingOrientationCoordinator.shared.run(
                    TuringPrerecordingOrientationRequest(
                        flowIdentity: flowIdentity,
                        descriptor: descriptor,
                        mediaItemID: clip.id,
                        mediaRole: clip.item.role,
                        interactionSurface: flowIdentity.interactionSurface
                    )
                )
                guard activeItem == .orientingAuthored(clip: clip) else {
                    return
                }
                activeItem = .none
            }
            let requestID = UUID()
            activeItem = .startingAuthored(
                clip: clip,
                requestID: requestID
            )
            print("""
            [TuringPlaybackTrace] authored bridge playback request
              id: \(clip.id)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              beforeGeneratedSegmentIndex: \(clip.beforeGeneratedSegmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            let handle = try await playOneShot(
                requestID: requestID,
                fileURL: clip.fileURL,
                kind: .prerecording,
                label: clip.id
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
            if case .startingAuthored(let pending, _) = activeItem,
               pending.id == clip.id {
                activeItem = .none
            }
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
            let requestID = UUID()
            activeItem = .startingGenerated(
                segmentIndex: clip.segmentIndex,
                requestID: requestID,
                fileURL: clip.fileURL
            )
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
                requestID: requestID,
                fileURL: clip.fileURL,
                kind: .generated,
                label: String(format: "segment_%04d", clip.segmentIndex)
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
            if case .startingGenerated(let index, _, _) = activeItem,
               index == clip.segmentIndex {
                activeItem = .none
            }
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
            let clip,
            let activeHandle,
            let fileURL,
            let startedAt
        )
            where activeHandle == handle:
            activeItem = .none
            pausedSpokenReceipts = pausedSpokenReceipts.filter {
                $0.value.handle != handle
            }
            resumeCurrentItemBoundaryWaiters()
            await emitLifecycleEvent(
                .authoredMediaCompleted(
                    runID: handle.runID,
                    itemID: clip.id,
                    handle: handle
                )
            )
            print("""
            [TuringStagedSpeech] authored bridge playback completed
              id: \(clip.id)
              handleID: \(handle.id.uuidString)
              file: \(fileURL.lastPathComponent)
              elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(startedAt)))
              beforeGeneratedSegmentIndex: \(clip.beforeGeneratedSegmentIndex)
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
            pausedSpokenReceipts = pausedSpokenReceipts.filter {
                $0.value.handle != handle
            }
            resumeCurrentItemBoundaryWaiters()
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
            if let expectedSegmentCount,
               segmentIndex + 1 >= expectedSegmentCount {
                await emitLifecycleEvent(
                    .generatedPlaybackCompleted(
                        runID: handle.runID,
                        finalSegmentIndex: segmentIndex
                    )
                )
            }
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
        if authoredOnlyRun {
            return authoredInputSealed &&
                authoredProgressionHolds.isEmpty &&
                pendingAuthoredBridges.isEmpty &&
                activeItem == .none
        }
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
        if let runID, authoredOnlyRun == false {
            await fileStore.endRun(runID, reason: "finish.\(reason)")
        }
        print("""
        [TuringPlaybackRebuild] run finished
          runID: \(runID ?? "nil")
          reason: \(reason)
        """)
        resumeWaiters()
        authoredOnlyRun = false
        authoredInputSealed = false
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

    private func resumeCurrentItemBoundaryWaiters() {
        let continuations = currentItemBoundaryWaiters
        currentItemBoundaryWaiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func emitLifecycleEvent(
        _ event: TuringFlowPlaybackLifecycleEvent
    ) async {
        await playbackLifecycleSink?.receivePlaybackLifecycleEvent(event)
        await lifecycleHub.yield(event)
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
        case .startingAuthored(let clip, let requestID):
            return "startingAuthored.\(clip.id).\(requestID.uuidString)"
        case .orientingAuthored(let clip):
            return "orientingAuthored.\(clip.id)"
        case .startingGenerated(let segmentIndex, let requestID, _):
            return "startingGenerated.\(segmentIndex).\(requestID.uuidString)"
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
            let clip,
            let handle,
            let fileURL,
            let startedAt
        ):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "authoredBridge.\(clip.id).before=\(clip.beforeGeneratedSegmentIndex).\(fileURL.lastPathComponent).\(handle.id.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
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
