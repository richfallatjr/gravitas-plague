import AVFoundation
import Foundation

@MainActor
final class TuringStoryWalkiePlaybackCoordinator {
    enum VoiceRoute: String, Sendable {
        case walkieSpatial
        case playerGlobal
    }

    struct Policy: Sendable {
        var firstSegmentPrerollFillerCount = 1
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
        var fillerDirectoryCandidates = [
            "Turing/Audio/big-mike-filler",
            "Turing/big-mike-filler",
            "big-mike-filler"
        ]
        var fillerExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "caf"]
    }

    private struct GeneratedClip {
        let segmentIndex: Int
        let fileURL: URL
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
    }

    private struct PrerecordingClip {
        let id: String
        let fileURL: URL
    }

    private enum ActiveItem: Equatable {
        case none
        case prerecording(
            id: String,
            handleID: UUID,
            fileURL: URL,
            startedAt: Date
        )
        case generated(
            segmentIndex: Int,
            handleID: UUID,
            fileURL: URL,
            startedAt: Date
        )
        case filler(
            handleID: UUID,
            fileURL: URL,
            startedAt: Date
        )
        case deadAir(id: UUID)
        case cancelled
    }

    private let policy: Policy
    private let rootURL: URL
    private let globalPlayer: (any TuringRichGlobalClipPlaying)?
    private var runDirectory: URL?
    private var runActive = false
    private var runID: String?
    private var expectedSegmentCount: Int?
    private var nextPlaybackSegmentIndex = 0
    private var completedGeneratedPlaybackCount = 0
    private var activeComputeSegments = Set<Int>()
    private var pendingGenerated: [Int: GeneratedClip] = [:]
    private var pendingPrerecording: PrerecordingClip?
    private var prerecordingHasPlayed = false
    private var skippedSegments = Set<Int>()
    private var allComputeFinished = false
    private var activeItem: ActiveItem = .none
    private var firstPrerollRemaining = 0
    private var lastFillerURL: URL?
    private var deadAirTask: Task<Void, Never>?
    private var waitContinuations: [CheckedContinuation<Void, Never>] = []
    private var fillerFiles: [URL]

    init(
        policy: Policy = Policy(),
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TuringStoryWalkiePlayback", isDirectory: true),
        globalPlayer: (any TuringRichGlobalClipPlaying)? = nil
    ) {
        self.policy = policy
        self.rootURL = rootURL
        self.globalPlayer = policy.voiceRoute == .playerGlobal
            ? (globalPlayer ?? TuringRichGlobalOneShotClipPlayer())
            : nil
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: policy.fillerDirectoryCandidates,
            allowedExtensions: policy.fillerExtensions
        )
    }

    static func makeBigMikeCoordinator() -> TuringStoryWalkiePlaybackCoordinator {
        TuringStoryWalkiePlaybackCoordinator()
    }

    static func makeRichGlobalCoordinator() -> TuringStoryWalkiePlaybackCoordinator {
        var policy = Policy()
        policy.voiceRoute = .playerGlobal
        policy.outputProcessingPolicy = .rich
        policy.generatedGainDB = 0
        policy.prerecordingGainDB = 0
        policy.fillerGainDB = -6
        policy.fillerDirectoryCandidates = TuringRichVoiceIdentity
            .fillerDirectoryCandidates

        return TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "TuringRichStoryPlayback",
                    isDirectory: true
                )
        )
    }

    func beginRun(runID: String, expectedSegmentCount: Int?) async {
        await runCancelled(reason: "beginNewRun")

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.nextPlaybackSegmentIndex = 0
        self.completedGeneratedPlaybackCount = 0
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.pendingPrerecording = nil
        self.prerecordingHasPlayed = false
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.allComputeFinished = false
        self.activeItem = .none
        self.firstPrerollRemaining = max(0, policy.firstSegmentPrerollFillerCount)
        self.deadAirTask?.cancel()
        self.deadAirTask = nil
        self.runActive = true

        let safeRunID = runID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = rootURL.appendingPathComponent(safeRunID, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.runDirectory = directory

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
        """)

        await reconcile(reason: "runStarted")
    }

    func enqueuePrerecording(id: String, fileURL: URL) async {
        guard runActive else { return }
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
        await reconcile(reason: "prerecordingQueued")
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
            let clip = try writeGeneratedWAV(
                audio: processedAudio,
                segmentIndex: segmentIndex
            )
            pendingGenerated[segmentIndex] = clip
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
        guard runActive else { return }
        allComputeFinished = true
        print("[TuringPlaybackRebuild] qwen compute all finished")
        await reconcile(reason: "computeAllFinished")
    }

    func waitUntilPlaybackFinished() async {
        if isFinished {
            return
        }

        await withCheckedContinuation { continuation in
            waitContinuations.append(continuation)
        }
    }

    func completedGeneratedSegmentCount() -> Int {
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
        cancelActivePlayback(reason: reason)
        cleanupAllWAVs(reason: "cancel.\(reason)")
        pendingGenerated.removeAll(keepingCapacity: false)
        pendingPrerecording = nil
        prerecordingHasPlayed = false
        skippedSegments.removeAll(keepingCapacity: false)
        activeComputeSegments.removeAll(keepingCapacity: false)
        print("""
        [TuringPlaybackRebuild] run cancelled
          reason: \(reason)
        """)
        resumeWaiters()
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

        if firstPrerollRemaining > 0,
           pendingGenerated[nextPlaybackSegmentIndex] != nil {
            firstPrerollRemaining -= 1
            await startFiller(reason: "firstSegmentPreroll.generatedReady")
            return
        }

        if let clip = pendingGenerated.removeValue(forKey: nextPlaybackSegmentIndex) {
            await startGenerated(clip, reason: reason)
            return
        }

        if activeComputeSegments.isEmpty == false,
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
        kind: TuringWalkieOneShotClipPlayer.ClipKind,
        label: String,
        completion: @escaping @MainActor (UUID, Bool) -> Void
    ) throws -> UUID {
        switch policy.voiceRoute {
        case .walkieSpatial:
            guard let clipPlayer = TuringStoryWalkieAudioRoute
                .makeActiveClipPlayer() else {
                throw TuringWalkieAudioError.missingWalkieEmitter
            }
            return try clipPlayer.playOneShot(
                fileURL: fileURL,
                kind: kind,
                label: label,
                completion: { handleID in
                    completion(handleID, true)
                }
            )

        case .playerGlobal:
            guard let globalPlayer else {
                throw NSError(
                    domain: "TuringPlaybackRebuild",
                    code: 20,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing global playback endpoint for \(label)."
                    ]
                )
            }
            let globalKind: TuringRichGlobalClipKind
            let gainDB: Float
            switch kind {
            case .generated:
                globalKind = .generated
                gainDB = policy.generatedGainDB
            case .prerecording:
                globalKind = .prerecording
                gainDB = policy.prerecordingGainDB
            case .filler:
                globalKind = .filler
                gainDB = policy.fillerGainDB
            case .commSFX:
                throw NSError(
                    domain: "TuringPlaybackRebuild",
                    code: 21,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Walkie comm SFX cannot use the global Rich voice route."
                    ]
                )
            }
            let handle = try globalPlayer.play(
                fileURL: fileURL,
                kind: globalKind,
                label: label,
                gainDB: gainDB,
                completion: { handle, successfully in
                    completion(handle.id, successfully)
                }
            )
            return handle.id
        }
    }

    private func cancelActivePlayback(reason: String) {
        switch policy.voiceRoute {
        case .walkieSpatial:
            TuringStoryWalkieAudioRoute.makeActiveClipPlayer()?
                .cancelAll(reason: reason)
        case .playerGlobal:
            globalPlayer?.cancelActive(reason: reason)
        }
    }

    private var voiceEmitterLogName: String {
        switch policy.voiceRoute {
        case .walkieSpatial:
            return "TuringStoryWalkieTalkie_AudioEmitter"
        case .playerGlobal:
            return "none"
        }
    }

    private var completionSourceLogName: String {
        switch policy.voiceRoute {
        case .walkieSpatial:
            return "AudioPlaybackController.completionHandler"
        case .playerGlobal:
            return "AVAudioPlayerDelegate.audioPlayerDidFinishPlaying"
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
            await notifyFirstPlaybackStarting(kind: "prerecording")
            print("""
            [TuringPlaybackTrace] prerecording playback request
              id: \(clip.id)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingGenerated: \(pendingGenerated.keys.sorted())
            """)
            let handleID = try playOneShot(
                fileURL: clip.fileURL,
                kind: .prerecording,
                label: clip.id,
                completion: { [weak self] handleID, successfully in
                    Task { @MainActor in
                        await self?.playbackCompleted(
                            handleID: handleID,
                            successfully: successfully
                        )
                    }
                }
            )
            activeItem = .prerecording(
                id: clip.id,
                handleID: handleID,
                fileURL: clip.fileURL,
                startedAt: Date()
            )
            print("""
            [TuringPlaybackRebuild] prerecording playback started
              id: \(clip.id)
              handleID: \(handleID.uuidString)
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

    private func startGenerated(_ clip: GeneratedClip, reason: String) async {
        guard activeItem == .none else {
            pendingGenerated[clip.segmentIndex] = clip
            return
        }
        do {
            await notifyFirstPlaybackStarting(kind: "generated")
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
            let handleID = try playOneShot(
                fileURL: clip.fileURL,
                kind: .generated,
                label: String(format: "segment_%04d", clip.segmentIndex),
                completion: { [weak self] handleID, successfully in
                    Task { @MainActor in
                        await self?.playbackCompleted(
                            handleID: handleID,
                            successfully: successfully
                        )
                    }
                }
            )
            let startedAt = Date()
            activeItem = .generated(
                segmentIndex: clip.segmentIndex,
                handleID: handleID,
                fileURL: clip.fileURL,
                startedAt: startedAt
            )
            print("""
            [TuringPlaybackRebuild] generated playback started
              segmentIndex: \(clip.segmentIndex)
              handleID: \(handleID.uuidString)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              voiceRoute: \(policy.voiceRoute.rawValue)
              spatialEmitter: \(voiceEmitterLogName)
              completionSource: \(completionSourceLogName)
              completionGate: coordinatorActiveHandleMatch
            """)
        } catch {
            skippedSegments.insert(clip.segmentIndex)
            cleanupWAV(clip.fileURL, reason: "generatedStartFailed")
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
            await notifyFirstPlaybackStarting(kind: "filler")
            print("""
            [TuringPlaybackTrace] filler playback request
              reason: \(reason)
              clip: \(fillerURL.lastPathComponent)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingNextReady: \(pendingGenerated[nextPlaybackSegmentIndex] != nil)
            """)
            let handleID = try playOneShot(
                fileURL: fillerURL,
                kind: .filler,
                label: fillerURL.deletingPathExtension().lastPathComponent,
                completion: { [weak self] handleID, successfully in
                    Task { @MainActor in
                        await self?.playbackCompleted(
                            handleID: handleID,
                            successfully: successfully
                        )
                    }
                }
            )
            lastFillerURL = fillerURL
            activeItem = .filler(
                handleID: handleID,
                fileURL: fillerURL,
                startedAt: Date()
            )
            print("""
            [TuringPlaybackRebuild] filler started
              reason: \(reason)
              clip: \(fillerURL.lastPathComponent)
              handleID: \(handleID.uuidString)
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
            await MainActor.run {
                Task { @MainActor in
                    await self?.deadAirFinished(id: id)
                }
            }
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

    private func notifyFirstPlaybackStarting(kind: String) async {
        await TuringWalkieCommsFXController.shared.stopSendingLeadIn(
            reason: "firstPlaybackStarting.\(kind)"
        )
    }

    private func playbackCompleted(
        handleID: UUID,
        successfully: Bool
    ) async {
        print("""
        [TuringPlaybackTrace] coordinator completion received
          handleID: \(handleID.uuidString)
          successfully: \(successfully)
          activeItemBeforeMatch: \(activeItemLog)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          pendingGenerated: \(pendingGenerated.keys.sorted())
        """)

        guard successfully else {
            print("""
            [TuringPlaybackRebuild] playback completion rejected
              handleID: \(handleID.uuidString)
              activeItem: \(activeItemLog)
              reason: playbackBackendReportedFailure
            """)
            await runCancelled(
                reason: "playbackBackendFailure.\(handleID.uuidString)"
            )
            return
        }

        switch activeItem {
        case .prerecording(
            let id,
            let activeHandleID,
            let fileURL,
            let startedAt
        )
            where activeHandleID == handleID:
            prerecordingHasPlayed = true
            firstPrerollRemaining = 0
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] prerecording playback completed
              id: \(id)
              handleID: \(handleID.uuidString)
              file: \(fileURL.lastPathComponent)
              elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(startedAt)))
              completionSource: \(completionSourceLogName)
              initialPrerollSatisfied: true
            """)
            await reconcile(reason: "prerecordingCompleted")

        case .generated(
            let segmentIndex,
            let activeHandleID,
            let fileURL,
            let startedAt
        )
            where activeHandleID == handleID:
            let elapsed = Date().timeIntervalSince(startedAt)
            print("""
            [TuringPlaybackTrace] generated completion accepted
              segmentIndex: \(segmentIndex)
              handleID: \(handleID.uuidString)
              elapsedSeconds: \(String(format: "%.3f", elapsed))
              willAdvanceToSegmentIndex: \(segmentIndex + 1)
            """)
            nextPlaybackSegmentIndex = segmentIndex + 1
            completedGeneratedPlaybackCount += 1
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] generated playback completed
              segmentIndex: \(segmentIndex)
              handleID: \(handleID.uuidString)
              completionSource: \(completionSourceLogName)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            cleanupWAV(fileURL, reason: "generatedPlaybackCompleted")
            await reconcile(reason: "generatedCompleted")

        case .filler(
            let activeHandleID,
            let fileURL,
            let startedAt
        )
            where activeHandleID == handleID:
            let elapsed = Date().timeIntervalSince(startedAt)
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] filler completed
              handleID: \(handleID.uuidString)
              clip: \(fileURL.lastPathComponent)
              elapsedSeconds: \(String(format: "%.3f", elapsed))
              pendingNextReady: \(pendingGenerated[nextPlaybackSegmentIndex] != nil)
            """)
            if pendingGenerated[nextPlaybackSegmentIndex] == nil,
               activeComputeSegments.isEmpty == false,
               policy.deadAirAfterFillerEnabled {
                startDeadAir(reason: "afterFiller")
                return
            }
            await reconcile(reason: "fillerCompleted")

        default:
            print("""
            [TuringPlaybackRebuild] stale playback completion ignored
              handleID: \(handleID.uuidString)
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
            skippedSegments.isEmpty &&
            activeItem == .none
    }

    private var shouldUseDeadAirWhileWaitingForInitialGeneratedSegment: Bool {
        nextPlaybackSegmentIndex == 0 && pendingGenerated[0] == nil
    }

    private func finishRun(reason: String) async {
        guard runActive else { return }
        runActive = false
        cleanupAllWAVs(reason: "finish.\(reason)")
        print("""
        [TuringPlaybackRebuild] run finished
          runID: \(runID ?? "nil")
          reason: \(reason)
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

    private func nextFillerURL() -> URL? {
        guard fillerFiles.isEmpty == false else { return nil }
        if policy.avoidImmediateFillerRepeat,
           fillerFiles.count > 1 {
            let candidates = fillerFiles.filter { $0 != lastFillerURL }
            return candidates.randomElement()
        }
        return fillerFiles.randomElement()
    }

    private func writeGeneratedWAV(
        audio: TuringComputeGapGeneratedAudio,
        segmentIndex: Int
    ) throws -> GeneratedClip {
        guard let runDirectory else {
            throw NSError(
                domain: "TuringPlaybackRebuild",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing playback run directory."]
            )
        }
        guard audio.samples.isEmpty == false else {
            throw NSError(
                domain: "TuringPlaybackRebuild",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Empty generated samples."]
            )
        }

        let channelCount = max(1, Int(audio.channelCount))
        let frameCount = audio.samples.count / channelCount
        guard frameCount > 0 else {
            throw NSError(
                domain: "TuringPlaybackRebuild",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Generated samples do not contain a full frame."]
            )
        }

        let finalURL = runDirectory
            .appendingPathComponent(String(format: "segment_%04d.wav", segmentIndex))
        let tmpURL = runDirectory
            .appendingPathComponent(String(format: "segment_%04d.tmp.wav", segmentIndex))
        try? FileManager.default.removeItem(at: tmpURL)
        try? FileManager.default.removeItem(at: finalURL)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]

        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: tmpURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                throw NSError(
                    domain: "TuringPlaybackRebuild",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not allocate generated PCM buffer."]
                )
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channels = buffer.floatChannelData else {
                throw NSError(
                    domain: "TuringPlaybackRebuild",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Missing generated PCM channel data."]
                )
            }

            if channelCount == 1 {
                for index in 0..<frameCount {
                    let value = audio.samples[index]
                    channels[0][index] = value.isFinite ? max(-1, min(1, value)) : 0
                }
            } else {
                for channelIndex in 0..<channelCount {
                    for frameIndex in 0..<frameCount {
                        let value = audio.samples[
                            frameIndex * channelCount + channelIndex
                        ]
                        channels[channelIndex][frameIndex] = value.isFinite
                            ? max(-1, min(1, value))
                            : 0
                    }
                }
            }

            try file.write(from: buffer)
        }

        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        let validation = try AVAudioFile(forReading: finalURL)
        let sampleRate = validation.fileFormat.sampleRate
        guard validation.length > 0, sampleRate > 0 else {
            throw NSError(
                domain: "TuringPlaybackRebuild",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Generated WAV validation produced zero frames."]
            )
        }

        return GeneratedClip(
            segmentIndex: segmentIndex,
            fileURL: finalURL,
            frameCount: validation.length,
            sampleRate: sampleRate
        )
    }

    private func cleanupWAV(_ url: URL, reason: String) {
        try? FileManager.default.removeItem(at: url)
        print("""
        [TuringPlaybackRebuild] generated wav cleaned
          file: \(url.lastPathComponent)
          reason: \(reason)
        """)
    }

    private func cleanupAllWAVs(reason: String) {
        for clip in pendingGenerated.values {
            cleanupWAV(clip.fileURL, reason: reason)
        }
        if let runDirectory {
            try? FileManager.default.removeItem(at: runDirectory)
        }
        runDirectory = nil
    }

    private var activeItemLog: String {
        switch activeItem {
        case .none:
            return "none"
        case .generated(
            let segmentIndex,
            let handleID,
            _,
            let startedAt
        ):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "generated.\(segmentIndex).\(handleID.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .prerecording(let id, let handleID, let fileURL, let startedAt):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "prerecording.\(id).\(fileURL.lastPathComponent).\(handleID.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .filler(let handleID, let fileURL, let startedAt):
            let elapsed = Date().timeIntervalSince(startedAt)
            return "filler.\(fileURL.lastPathComponent).\(handleID.uuidString).elapsed=\(Self.formatSeconds(elapsed))"
        case .deadAir(let id):
            return "deadAir.\(id.uuidString)"
        case .cancelled:
            return "cancelled"
        }
    }

    private static func discoverFillerFiles(
        candidates: [String],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var discovered: [URL] = []
        for candidate in candidates {
            let urls = [
                Bundle.main.resourceURL?.appendingPathComponent(candidate),
                Bundle.main.bundleURL.appendingPathComponent(candidate),
                URL(fileURLWithPath: candidate)
            ].compactMap { $0 }

            for directory in urls {
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ) else {
                    continue
                }
                for file in contents {
                    let ext = file.pathExtension.lowercased()
                    guard allowedExtensions.contains(ext) else { continue }
                    let weight = fillerWeight(from: file)
                    discovered.append(contentsOf: Array(repeating: file, count: weight))
                }
            }
        }
        return discovered
    }

    private static func fillerWeight(from url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let suffix = stem.split(separator: "_").last,
              let weight = Int(suffix) else {
            return 1
        }
        return max(1, min(10, weight))
    }

    private static func formatSeconds(_ seconds: Double?) -> String {
        guard let seconds else {
            return "nil"
        }
        return String(format: "%.3f", seconds)
    }
}
