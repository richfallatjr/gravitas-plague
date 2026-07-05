import AVFoundation
import Foundation

public struct TuringComputeGapGeneratedAudio: Sendable {
    public let segmentIndex: Int
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount

    public init(
        segmentIndex: Int,
        samples: [Float],
        sampleRate: Double,
        channelCount: AVAudioChannelCount = 1
    ) {
        self.segmentIndex = segmentIndex
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct TuringComputeGapAudioPolicy: Sendable {
    public var playOneFillerBeforeFirstGeneratedSegment: Bool
    public var firstSegmentPrerollFillerCount: Int
    public var minimumFillerClipsBetweenRealSegments: Int
    public var completeCurrentFillerBeforeRealSpeech: Bool
    public var chainFillerWhileComputeWithoutSpeech: Bool
    public var avoidImmediateFillerRepeat: Bool
    public var preparedBacklogPauseThreshold: Int
    public var preparedBacklogPauseSeconds: Double

    public init(
        playOneFillerBeforeFirstGeneratedSegment: Bool = true,
        firstSegmentPrerollFillerCount: Int = 1,
        minimumFillerClipsBetweenRealSegments: Int = 1,
        completeCurrentFillerBeforeRealSpeech: Bool = true,
        chainFillerWhileComputeWithoutSpeech: Bool = true,
        avoidImmediateFillerRepeat: Bool = true,
        preparedBacklogPauseThreshold: Int = 1,
        preparedBacklogPauseSeconds: Double = 0.25
    ) {
        self.playOneFillerBeforeFirstGeneratedSegment = playOneFillerBeforeFirstGeneratedSegment
        self.firstSegmentPrerollFillerCount = firstSegmentPrerollFillerCount
        self.minimumFillerClipsBetweenRealSegments = minimumFillerClipsBetweenRealSegments
        self.completeCurrentFillerBeforeRealSpeech = completeCurrentFillerBeforeRealSpeech
        self.chainFillerWhileComputeWithoutSpeech = chainFillerWhileComputeWithoutSpeech
        self.avoidImmediateFillerRepeat = avoidImmediateFillerRepeat
        self.preparedBacklogPauseThreshold = preparedBacklogPauseThreshold
        self.preparedBacklogPauseSeconds = preparedBacklogPauseSeconds
    }

    public static let bigMikeDefault = TuringComputeGapAudioPolicy()
}

@MainActor
public final class TuringComputeGapAudioCoordinator {
    public struct Configuration: Sendable {
        public var fillerDirectoryCandidates: [String]
        public var fillerExtensions: Set<String>
        public var fillerVolume: Float
        public var realSpeechVolume: Float
        public var fillerFadeOutSeconds: Double
        public var longStallWarningSeconds: Double

        public init(
            fillerDirectoryCandidates: [String] = [
                "Turing/Audio/big-mike-filler",
                "Turing/big-mike-filler",
                "big-mike-filler"
            ],
            fillerExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "caf"],
            fillerVolume: Float = 0.58,
            realSpeechVolume: Float = 1.0,
            fillerFadeOutSeconds: Double = 0.20,
            longStallWarningSeconds: Double = 15.0
        ) {
            self.fillerDirectoryCandidates = fillerDirectoryCandidates
            self.fillerExtensions = fillerExtensions
            self.fillerVolume = fillerVolume
            self.realSpeechVolume = realSpeechVolume
            self.fillerFadeOutSeconds = fillerFadeOutSeconds
            self.longStallWarningSeconds = longStallWarningSeconds
        }
    }

    public enum CoordinatorError: LocalizedError {
        case noOutputAudioFormat
        case invalidGeneratedAudio(segmentIndex: Int)
        case invalidFillerAudio(String)
        case audioConversionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noOutputAudioFormat:
                return "Unable to create output audio format."
            case .invalidGeneratedAudio(let segmentIndex):
                return "Generated audio for segment \(segmentIndex) is empty or invalid."
            case .invalidFillerAudio(let path):
                return "Filler audio is empty or invalid: \(path)"
            case .audioConversionFailed(let message):
                return "Audio conversion failed: \(message)"
            }
        }
    }

    private let configuration: Configuration
    private let policy: TuringComputeGapAudioPolicy
    private let engine = AVAudioEngine()
    private let realSpeechNode = AVAudioPlayerNode()
    private let fillerNode = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?

    private var fillerFiles: [URL] = []
    private var fillerQueue: [URL] = []
    private var lastFillerFile: URL?
    private var fillerGeneration = 0
    private var fillerFadeTask: Task<Void, Never>?
    private var longStallWarningTask: Task<Void, Never>?
    private var shortPauseTask: Task<Void, Never>?

    private var runID: String?
    private var expectedSegmentCount: Int?
    private var runActive = false
    private var allComputeFinished = false
    private var activeComputeSegmentIndices = Set<Int>()
    private var realSpeechPlayingSegmentIndex: Int?
    private var pendingGeneratedSegments: [Int: TuringComputeGapGeneratedAudio] = [:]
    private var nextPlaybackSegmentIndex = 0
    private var fillerPlaying = false
    private var fillerStopAfterCurrent = false
    private var shortPauseActive = false
    private var firstSegmentPrerollRemaining = 0
    private var interSegmentFillerRemaining = 0
    private var playbackFinishedContinuation: CheckedContinuation<Void, Never>?

    public init(
        configuration: Configuration = Configuration(),
        policy: TuringComputeGapAudioPolicy = .bigMikeDefault
    ) throws {
        self.configuration = configuration
        self.policy = policy
        try configureAudioSessionIfAvailable()
        try configureEngine()
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: configuration.fillerDirectoryCandidates,
            allowedExtensions: configuration.fillerExtensions
        )
        print("""
        [TuringGapAudio] initialized
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          fillerWeightFilenameSuffix: _1..._10
          playbackSampleRate: \(playbackFormat?.sampleRate ?? 0)
          playbackChannelCount: \(playbackFormat?.channelCount ?? 0)
          playOneFillerBeforeFirstGeneratedSegment: \(policy.playOneFillerBeforeFirstGeneratedSegment)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          minimumFillerClipsBetweenRealSegments: \(policy.minimumFillerClipsBetweenRealSegments)
          completeCurrentFillerBeforeRealSpeech: \(policy.completeCurrentFillerBeforeRealSpeech)
          chainFillerWhileComputeWithoutSpeech: \(policy.chainFillerWhileComputeWithoutSpeech)
          preparedBacklogPauseThreshold: \(policy.preparedBacklogPauseThreshold)
          preparedBacklogPauseSeconds: \(String(format: "%.2f", policy.preparedBacklogPauseSeconds))
        """)
    }

    public static func makeBigMikeCoordinator() throws -> TuringComputeGapAudioCoordinator {
        try TuringComputeGapAudioCoordinator()
    }

    public func beginRun(
        runID: String,
        expectedSegmentCount: Int? = nil
    ) async {
        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.runActive = true
        self.allComputeFinished = false
        self.activeComputeSegmentIndices.removeAll(keepingCapacity: true)
        self.realSpeechPlayingSegmentIndex = nil
        self.pendingGeneratedSegments.removeAll(keepingCapacity: true)
        self.nextPlaybackSegmentIndex = 0
        self.fillerGeneration &+= 1
        self.fillerQueue.removeAll(keepingCapacity: true)
        self.fillerPlaying = false
        self.fillerStopAfterCurrent = false
        self.shortPauseActive = false
        self.shortPauseTask?.cancel()
        self.shortPauseTask = nil
        self.firstSegmentPrerollRemaining = policy.playOneFillerBeforeFirstGeneratedSegment
            ? max(0, policy.firstSegmentPrerollFillerCount)
            : 0
        self.interSegmentFillerRemaining = 0
        realSpeechNode.stop()
        fillerNode.stop()
        realSpeechNode.reset()
        fillerNode.reset()
        startEngineIfNeeded()
        print("""
        [TuringGapAudio] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          firstSegmentPrerollRemaining: \(firstSegmentPrerollRemaining)
          minimumFillerClipsBetweenRealSegments: \(policy.minimumFillerClipsBetweenRealSegments)
          preparedBacklogPauseThreshold: \(policy.preparedBacklogPauseThreshold)
          preparedBacklogPauseSeconds: \(String(format: "%.2f", policy.preparedBacklogPauseSeconds))
        """)
        await reconcile(reason: "runStarted")
    }

    public func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        activeComputeSegmentIndices.insert(segmentIndex)
        print("""
        [TuringGapAudio] qwen compute started
          segmentIndex: \(segmentIndex)
          activeComputeSegments: \(formattedActiveComputeSegments)
          realSpeechPlaying: \(realSpeechPlayingSegmentIndex.map(String.init) ?? "nil")
          fillerPlaying: \(fillerPlaying)
        """)
        await reconcile(reason: "computeStarted")
    }

    public func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async {
        guard runActive else { return }
        activeComputeSegmentIndices.remove(segmentIndex)

        guard segmentIndex >= nextPlaybackSegmentIndex else {
            print("""
            [TuringGapAudio] stale generated segment discarded
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              realSpeechPlaying: \(realSpeechPlayingSegmentIndex.map(String.init) ?? "nil")
            """)
            return
        }

        guard realSpeechPlayingSegmentIndex != segmentIndex else {
            print("""
            [TuringGapAudio] generated segment discarded because it is already playing
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }

        guard pendingGeneratedSegments[segmentIndex] == nil else {
            print("""
            [TuringGapAudio] duplicate pending generated segment discarded
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }

        let processedAudio = await TuringQwenOutputPostProcessor.processForPlayback(
            audio,
            reason: "computeGapAudio"
        )

        guard runActive else { return }
        guard segmentIndex >= nextPlaybackSegmentIndex,
              realSpeechPlayingSegmentIndex != segmentIndex,
              pendingGeneratedSegments[segmentIndex] == nil else {
            print("""
            [TuringGapAudio] generated segment discarded after postprocess
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              realSpeechPlaying: \(realSpeechPlayingSegmentIndex.map(String.init) ?? "nil")
            """)
            return
        }

        pendingGeneratedSegments[segmentIndex] = processedAudio
        print("""
        [TuringGapAudio] qwen compute finished
          segmentIndex: \(segmentIndex)
          sampleCount: \(processedAudio.samples.count)
          sampleRate: \(processedAudio.sampleRate)
          pendingCount: \(pendingGeneratedSegments.count)
          fillerPlaying: \(fillerPlaying)
        """)

        if fillerPlaying,
           segmentIndex == nextPlaybackSegmentIndex,
           policy.completeCurrentFillerBeforeRealSpeech {
            if segmentIndex == 0,
               firstSegmentPrerollRemaining > 0 {
                firstSegmentPrerollRemaining = 0
                print("""
                [TuringGapAudio] first segment ready; preroll filler required
                  segmentIndex: \(segmentIndex)
                  fillerClipsRemaining: 0
                """)
            }
            fillerStopAfterCurrent = true
            print("""
            [TuringGapAudio] real speech ready while filler active; deferring until filler finishes
              segmentIndex: \(segmentIndex)
              shortPauseSkipped: true
            """)
        }

        await reconcile(reason: "computeFinished")
    }

    public func qwenComputeFailed(
        segmentIndex: Int,
        error: Error
    ) async {
        print("""
        [TuringGapAudio] qwen compute failed
          segmentIndex: \(segmentIndex)
          error: \(error.localizedDescription)
        """)
        activeComputeSegmentIndices.remove(segmentIndex)
        await runCancelled(reason: "qwenComputeFailed.segment\(segmentIndex)")
    }

    public func qwenComputeAllFinished() async {
        allComputeFinished = true
        print("[TuringGapAudio] qwen compute all finished")
        await reconcile(reason: "computeAllFinished")
    }

    public func waitUntilPlaybackFinished() async {
        if isRunFinished {
            return
        }
        await withCheckedContinuation { continuation in
            playbackFinishedContinuation = continuation
        }
    }

    public func runCancelled(reason: String) async {
        guard runActive else { return }
        print("""
        [TuringGapAudio] run cancelled
          reason: \(reason)
        """)
        runActive = false
        activeComputeSegmentIndices.removeAll(keepingCapacity: false)
        allComputeFinished = true
        pendingGeneratedSegments.removeAll(keepingCapacity: false)
        realSpeechPlayingSegmentIndex = nil
        fillerPlaying = false
        fillerStopAfterCurrent = false
        shortPauseActive = false
        shortPauseTask?.cancel()
        shortPauseTask = nil
        firstSegmentPrerollRemaining = 0
        interSegmentFillerRemaining = 0
        longStallWarningTask?.cancel()
        longStallWarningTask = nil
        await stopFiller(reason: "cancelled", fade: false)
        realSpeechNode.stop()
        realSpeechNode.reset()
        finishWaiterIfNeeded()
    }

    private var isRunFinished: Bool {
        runActive == false || (
            allComputeFinished &&
            activeComputeSegmentIndices.isEmpty &&
            realSpeechPlayingSegmentIndex == nil &&
            fillerPlaying == false &&
            shortPauseActive == false &&
            pendingGeneratedSegments.isEmpty
        )
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }

        if realSpeechPlayingSegmentIndex != nil {
            return
        }

        if fillerPlaying {
            if pendingGeneratedSegments[nextPlaybackSegmentIndex] != nil,
               policy.completeCurrentFillerBeforeRealSpeech {
                fillerStopAfterCurrent = true
            }
            return
        }

        if shortPauseActive {
            return
        }

        if shouldPlayFirstSegmentPreroll {
            firstSegmentPrerollRemaining -= 1
            print("""
            [TuringGapAudio] first segment ready; preroll filler required
              segmentIndex: \(nextPlaybackSegmentIndex)
              fillerClipsRemaining: \(firstSegmentPrerollRemaining)
            """)
            startFillerIfNeeded(
                reason: "firstSegmentPreroll",
                waitingForSegmentIndex: nextPlaybackSegmentIndex
            )
            return
        }

        if shouldPlayInterSegmentFiller {
            interSegmentFillerRemaining -= 1
            print("""
            [TuringGapAudio] inter-segment filler required
              previousSegmentIndex: \(nextPlaybackSegmentIndex - 1)
              waitingForSegmentIndex: \(nextPlaybackSegmentIndex)
              fillerClipsRemaining: \(interSegmentFillerRemaining)
            """)
            if shouldUsePreparedBacklogPause {
                startPreparedBacklogPause(
                    waitingForSegmentIndex: nextPlaybackSegmentIndex
                )
                return
            }
            startFillerIfNeeded(
                reason: "interSegmentBuffer",
                waitingForSegmentIndex: nextPlaybackSegmentIndex
            )
            return
        }

        if let audio = pendingGeneratedSegments.removeValue(forKey: nextPlaybackSegmentIndex) {
            await startRealSpeech(audio, reason: reason)
            return
        }

        if activeComputeSegmentIndices.isEmpty == false {
            let waitingForSegmentIndex = activeComputeSegmentIndices.contains(nextPlaybackSegmentIndex)
                ? nextPlaybackSegmentIndex
                : (activeComputeSegmentIndices.sorted().first ?? nextPlaybackSegmentIndex)
            if policy.chainFillerWhileComputeWithoutSpeech,
               nextPlaybackSegmentIndex > 0 {
                startFillerIfNeeded(
                    reason: "computeWithoutSpeech",
                    waitingForSegmentIndex: waitingForSegmentIndex
                )
            } else if nextPlaybackSegmentIndex == 0 {
                print("""
                [TuringGapAudio] pre-first-segment compute bridged by radio static
                  waitingForSegmentIndex: \(waitingForSegmentIndex)
                  activeComputeSegments: \(formattedActiveComputeSegments)
                """)
            }
            return
        }

        if allComputeFinished,
           pendingGeneratedSegments.isEmpty == false,
           pendingGeneratedSegments[nextPlaybackSegmentIndex] == nil {
            print("""
            [TuringGapAudio] missing next generated segment after compute finished
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              pendingSegmentIndexes: \(formattedPendingGeneratedSegments)
              activeComputeSegments: \(formattedActiveComputeSegments)
            """)
            await runCancelled(
                reason: "missingNextGeneratedSegment.\(nextPlaybackSegmentIndex)"
            )
            return
        }

        if allComputeFinished && pendingGeneratedSegments.isEmpty {
            await stopFiller(reason: "runFinished", fade: false)
            runActive = false
            print("""
            [TuringGapAudio] run finished
              runID: \(runID ?? "nil")
            """)
            finishWaiterIfNeeded()
        }
    }

    private var shouldPlayFirstSegmentPreroll: Bool {
        runActive &&
        nextPlaybackSegmentIndex == 0 &&
        firstSegmentPrerollRemaining > 0 &&
        pendingGeneratedSegments[0] != nil &&
        realSpeechPlayingSegmentIndex == nil &&
        fillerPlaying == false
    }

    private var shouldUsePreparedBacklogPause: Bool {
        pendingGeneratedSegments.count >= max(1, policy.preparedBacklogPauseThreshold) &&
        pendingGeneratedSegments[nextPlaybackSegmentIndex] != nil &&
        policy.preparedBacklogPauseSeconds > 0
    }

    private var shouldPlayInterSegmentFiller: Bool {
        runActive &&
        nextPlaybackSegmentIndex > 0 &&
        interSegmentFillerRemaining > 0 &&
        pendingGeneratedSegments[nextPlaybackSegmentIndex] != nil &&
        realSpeechPlayingSegmentIndex == nil &&
        fillerPlaying == false
    }

    private func startRealSpeech(
        _ audio: TuringComputeGapGeneratedAudio,
        reason: String
    ) async {
        guard runActive else { return }
        guard audio.segmentIndex == nextPlaybackSegmentIndex else {
            pendingGeneratedSegments[audio.segmentIndex] = audio
            print("""
            [TuringGapAudio] out-of-order real speech start prevented
              segmentIndex: \(audio.segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              realSpeechPlaying: \(realSpeechPlayingSegmentIndex.map(String.init) ?? "nil")
            """)
            return
        }
        guard realSpeechPlayingSegmentIndex == nil else {
            pendingGeneratedSegments[audio.segmentIndex] = audio
            print("""
            [TuringGapAudio] real speech start prevented while another segment is playing
              segmentIndex: \(audio.segmentIndex)
              currentSegmentIndex: \(realSpeechPlayingSegmentIndex.map(String.init) ?? "nil")
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }
        guard fillerPlaying == false else {
            pendingGeneratedSegments[audio.segmentIndex] = audio
            fillerStopAfterCurrent = true
            print("""
            [TuringGapAudio] real speech ready while filler active; deferring until filler finishes
              segmentIndex: \(audio.segmentIndex)
            """)
            return
        }

        guard audio.samples.isEmpty == false,
              audio.samples.allSatisfy({ $0.isFinite }) else {
            print("""
            [TuringGapAudio] invalid generated audio
              segmentIndex: \(audio.segmentIndex)
            """)
            await runCancelled(reason: "invalidGeneratedAudio")
            return
        }

        do {
            let buffer = try makePCMBuffer(audio)
            realSpeechPlayingSegmentIndex = audio.segmentIndex
            realSpeechNode.volume = configuration.realSpeechVolume
            realSpeechNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.realSpeechFinished(segmentIndex: audio.segmentIndex)
                }
            }
            if realSpeechNode.isPlaying == false {
                realSpeechNode.play()
            }
            print("""
            [TuringGapAudio] real speech started
              segmentIndex: \(audio.segmentIndex)
              reason: \(reason)
            """)
        } catch {
            print("""
            [TuringGapAudio] real speech start failed
              segmentIndex: \(audio.segmentIndex)
              error: \(error.localizedDescription)
            """)
            await runCancelled(reason: "realSpeechStartFailed")
        }
    }

    private func realSpeechFinished(segmentIndex: Int) async {
        guard runActive else { return }
        guard realSpeechPlayingSegmentIndex == segmentIndex else { return }
        realSpeechPlayingSegmentIndex = nil
        nextPlaybackSegmentIndex = max(nextPlaybackSegmentIndex, segmentIndex + 1)
        if shouldRequireFillerAfterRealSpeech(finishedSegmentIndex: segmentIndex) {
            interSegmentFillerRemaining = max(
                interSegmentFillerRemaining,
                policy.minimumFillerClipsBetweenRealSegments
            )
        }
        print("""
        [TuringGapAudio] real speech finished
          segmentIndex: \(segmentIndex)
          interSegmentFillerRemaining: \(interSegmentFillerRemaining)
        """)
        await reconcile(reason: "realSpeechFinished")
    }

    private func shouldRequireFillerAfterRealSpeech(
        finishedSegmentIndex: Int
    ) -> Bool {
        guard policy.minimumFillerClipsBetweenRealSegments > 0 else {
            return false
        }

        if let expectedSegmentCount {
            return finishedSegmentIndex + 1 < expectedSegmentCount
        }

        return pendingGeneratedSegments[finishedSegmentIndex + 1] != nil ||
            activeComputeSegmentIndices.isEmpty == false ||
            allComputeFinished == false
    }

    private func startFillerIfNeeded(
        reason: String,
        waitingForSegmentIndex: Int
    ) {
        guard runActive else { return }
        guard realSpeechPlayingSegmentIndex == nil else { return }
        guard fillerFiles.isEmpty == false else {
            print("""
            [TuringGapAudio] filler unavailable
              reason: noFillerClips
              waitingForSegmentIndex: \(waitingForSegmentIndex)
            """)
            return
        }

        if fillerPlaying {
            return
        }

        fillerFadeTask?.cancel()
        fillerGeneration &+= 1
        let generation = fillerGeneration
        fillerPlaying = true
        fillerStopAfterCurrent = false
        fillerNode.stop()
        fillerNode.reset()
        fillerNode.volume = configuration.fillerVolume
        scheduleNextFillerClip(generation: generation, firstInChain: true)
        fillerNode.play()
        print("""
        [TuringGapAudio] filler started
          reason: \(reason)
          waitingForSegmentIndex: \(waitingForSegmentIndex)
        """)
        scheduleLongStallWarning(waitingForSegmentIndex: waitingForSegmentIndex)
    }

    private func startPreparedBacklogPause(
        waitingForSegmentIndex: Int
    ) {
        guard runActive else { return }
        guard shortPauseActive == false else { return }

        shortPauseTask?.cancel()
        shortPauseActive = true
        let seconds = policy.preparedBacklogPauseSeconds
        print("""
        [TuringGapAudio] prepared backlog pause started
          waitingForSegmentIndex: \(waitingForSegmentIndex)
          pendingPreparedCount: \(pendingGeneratedSegments.count)
          seconds: \(String(format: "%.2f", seconds))
        """)

        shortPauseTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(seconds * 1_000_000_000)
            )
            await MainActor.run {
                guard let self else { return }
                self.shortPauseActive = false
                self.shortPauseTask = nil
                print("""
                [TuringGapAudio] prepared backlog pause finished
                  waitingForSegmentIndex: \(waitingForSegmentIndex)
                  pendingPreparedCount: \(self.pendingGeneratedSegments.count)
                """)
                Task { @MainActor in
                    await self.reconcile(reason: "preparedBacklogPauseFinished")
                }
            }
        }
    }

    private func scheduleNextFillerClip(
        generation: Int,
        firstInChain: Bool
    ) {
        guard runActive else { return }
        guard generation == fillerGeneration else { return }
        guard realSpeechPlayingSegmentIndex == nil else { return }
        guard fillerStopAfterCurrent == false else { return }
        guard fillerFiles.isEmpty == false else { return }

        let selected = randomFillerURL()
        lastFillerFile = selected

        do {
            let buffer = try makeFillerBuffer(from: selected)
            fillerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.fillerClipFinished(
                        generation: generation,
                        clipURL: selected
                    )
                }
            }
            print("""
            [TuringGapAudio] filler clip \(firstInChain ? "started" : "chained")
              clip: \(selected.lastPathComponent)
            """)
        } catch {
            print("""
            [TuringGapAudio] filler clip load failed
              clip: \(selected.path)
              error: \(error.localizedDescription)
            """)
            let remaining = fillerFiles.filter { $0 != selected }
            fillerFiles = remaining
            fillerQueue.removeAll { $0 == selected }
            if fillerFiles.isEmpty == false {
                scheduleNextFillerClip(generation: generation, firstInChain: false)
            }
        }
    }

    private func fillerClipFinished(
        generation: Int,
        clipURL: URL
    ) async {
        guard runActive else { return }
        guard generation == fillerGeneration else { return }

        fillerPlaying = false
        fillerNode.stop()
        fillerNode.reset()

        print("""
        [TuringGapAudio] filler clip finished
          clip: \(clipURL.lastPathComponent)
          stopAfterCurrent: \(fillerStopAfterCurrent)
          pendingNextReady: \(pendingGeneratedSegments[nextPlaybackSegmentIndex] != nil)
          activeComputeSegments: \(formattedActiveComputeSegments)
        """)

        if fillerStopAfterCurrent {
            fillerStopAfterCurrent = false
            await reconcile(reason: "fillerClipFinished")
            return
        }

        if realSpeechPlayingSegmentIndex == nil,
           activeComputeSegmentIndices.isEmpty == false,
           pendingGeneratedSegments[nextPlaybackSegmentIndex] == nil,
           policy.chainFillerWhileComputeWithoutSpeech {
            print("""
            [TuringGapAudio] filler clip chained
              reason: computeWithoutSpeech
              waitingForSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
        }

        await reconcile(reason: "fillerClipFinished")
    }

    private func stopFiller(reason: String, fade: Bool) async {
        longStallWarningTask?.cancel()
        longStallWarningTask = nil

        guard fillerPlaying || fillerNode.isPlaying else {
            fillerGeneration &+= 1
            fillerPlaying = false
            fillerStopAfterCurrent = false
            fillerNode.stop()
            fillerNode.reset()
            return
        }

        print("""
        [TuringGapAudio] filler stopping
          reason: \(reason)
        """)

        fillerGeneration &+= 1
        fillerPlaying = false
        fillerStopAfterCurrent = false
        fillerFadeTask?.cancel()

        if fade && configuration.fillerFadeOutSeconds > 0 {
            let steps = 8
            let startVolume = fillerNode.volume
            let sleepNanos = UInt64((configuration.fillerFadeOutSeconds / Double(steps)) * 1_000_000_000)
            for step in 1...steps {
                if Task.isCancelled { break }
                let t = Float(step) / Float(steps)
                fillerNode.volume = max(0, startVolume * (1 - t))
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }

        fillerNode.stop()
        fillerNode.reset()
        fillerNode.volume = configuration.fillerVolume
    }

    private func scheduleLongStallWarning(waitingForSegmentIndex: Int) {
        longStallWarningTask?.cancel()
        longStallWarningTask = Task { [weak self] in
            guard let self else { return }
            let seconds = await MainActor.run { self.configuration.longStallWarningSeconds }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                guard self.runActive,
                      self.realSpeechPlayingSegmentIndex == nil,
                      (
                          self.activeComputeSegmentIndices.contains(waitingForSegmentIndex) ||
                          self.activeComputeSegmentIndices.isEmpty == false
                      ) else { return }
                print("""
                [TuringGapAudio] long compute gap still bridged by filler
                  waitingForSegmentIndex: \(waitingForSegmentIndex)
                  nextPlaybackSegmentIndex: \(self.nextPlaybackSegmentIndex)
                  activeComputeSegments: \(self.formattedActiveComputeSegments)
                  seconds: \(seconds)
                """)
            }
        }
    }

    private var formattedActiveComputeSegments: String {
        guard activeComputeSegmentIndices.isEmpty == false else {
            return "none"
        }
        return activeComputeSegmentIndices
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }

    private var formattedPendingGeneratedSegments: String {
        guard pendingGeneratedSegments.isEmpty == false else {
            return "none"
        }
        return pendingGeneratedSegments.keys
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }

    private func randomFillerURL() -> URL {
        if fillerQueue.isEmpty {
            rebuildFillerQueue()
        }

        if policy.avoidImmediateFillerRepeat,
           let lastFillerFile,
           fillerQueue.count > 1,
           fillerQueue.first == lastFillerFile,
           let replacementIndex = fillerQueue.firstIndex(where: { $0 != lastFillerFile }) {
            fillerQueue.swapAt(0, replacementIndex)
        }

        guard fillerQueue.isEmpty == false else {
            return fillerFiles.randomElement() ?? fillerFiles[0]
        }

        return fillerQueue.removeFirst()
    }

    private func rebuildFillerQueue() {
        fillerQueue = fillerFiles.shuffled()

        if policy.avoidImmediateFillerRepeat,
           let lastFillerFile,
           fillerQueue.count > 1,
           fillerQueue.first == lastFillerFile,
           let replacementIndex = fillerQueue.firstIndex(where: { $0 != lastFillerFile }) {
            fillerQueue.swapAt(0, replacementIndex)
        }

        print("""
        [TuringGapAudio] filler weighted queue rebuilt
          uniqueClipCount: \(Set(fillerFiles).count)
          weightedEntryCount: \(fillerQueue.count)
          lastClip: \(lastFillerFile?.lastPathComponent ?? "nil")
        """)
    }

    private func makePCMBuffer(
        _ audio: TuringComputeGapGeneratedAudio
    ) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: audio.channelCount,
            interleaved: false
        ) else {
            throw CoordinatorError.noOutputAudioFormat
        }

        let frameCount = AVAudioFrameCount(audio.samples.count / Int(audio.channelCount))
        guard frameCount > 0 else {
            throw CoordinatorError.invalidGeneratedAudio(segmentIndex: audio.segmentIndex)
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCount
        ) else {
            throw CoordinatorError.invalidGeneratedAudio(segmentIndex: audio.segmentIndex)
        }
        buffer.frameLength = frameCount

        if audio.channelCount == 1 {
            guard let channel = buffer.floatChannelData?[0] else {
                throw CoordinatorError.invalidGeneratedAudio(segmentIndex: audio.segmentIndex)
            }
            audio.samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    channel.update(from: base, count: Int(frameCount))
                }
            }
        } else {
            guard let channels = buffer.floatChannelData else {
                throw CoordinatorError.invalidGeneratedAudio(segmentIndex: audio.segmentIndex)
            }
            let channelCount = Int(audio.channelCount)
            for channelIndex in 0..<channelCount {
                for frameIndex in 0..<Int(frameCount) {
                    channels[channelIndex][frameIndex] = audio.samples[frameIndex * channelCount + channelIndex]
                }
            }
        }
        return try convertToPlaybackFormat(buffer, context: "generated.segment\(audio.segmentIndex)")
    }

    private func makeFillerBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let frameCapacity = AVAudioFrameCount(file.length)
        guard frameCapacity > 0 else {
            throw CoordinatorError.invalidFillerAudio(url.path)
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw CoordinatorError.invalidFillerAudio(url.path)
        }
        try file.read(into: sourceBuffer)
        guard sourceBuffer.frameLength > 0 else {
            throw CoordinatorError.invalidFillerAudio(url.path)
        }
        return try convertToPlaybackFormat(sourceBuffer, context: "filler.\(url.lastPathComponent)")
    }

    private func convertToPlaybackFormat(
        _ sourceBuffer: AVAudioPCMBuffer,
        context: String
    ) throws -> AVAudioPCMBuffer {
        guard let playbackFormat else {
            throw CoordinatorError.noOutputAudioFormat
        }

        if sourceBuffer.format.sampleRate == playbackFormat.sampleRate,
           sourceBuffer.format.channelCount == playbackFormat.channelCount,
           sourceBuffer.format.commonFormat == playbackFormat.commonFormat,
           sourceBuffer.format.isInterleaved == playbackFormat.isInterleaved {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(
            from: sourceBuffer.format,
            to: playbackFormat
        ) else {
            throw CoordinatorError.audioConversionFailed("Could not create converter for \(context).")
        }

        let sampleRateRatio = playbackFormat.sampleRate / max(sourceBuffer.format.sampleRate, 1)
        let targetFrameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(sourceBuffer.frameLength) * sampleRateRatio) + 32)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: targetFrameCapacity
        ) else {
            throw CoordinatorError.audioConversionFailed("Could not allocate converted buffer for \(context).")
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: convertedBuffer,
            error: &conversionError
        ) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw CoordinatorError.audioConversionFailed("Converter returned error for \(context).")
        @unknown default:
            throw CoordinatorError.audioConversionFailed("Converter returned unknown status for \(context).")
        }

        guard convertedBuffer.frameLength > 0 else {
            throw CoordinatorError.audioConversionFailed("Converted buffer is empty for \(context).")
        }

        print("""
        [TuringGapAudio] audio converted for playback
          context: \(context)
          sourceSampleRate: \(sourceBuffer.format.sampleRate)
          sourceChannelCount: \(sourceBuffer.format.channelCount)
          playbackSampleRate: \(playbackFormat.sampleRate)
          playbackChannelCount: \(playbackFormat.channelCount)
        """)
        return convertedBuffer
    }

    private func configureEngine() throws {
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
        let channelCount = outputFormat.channelCount > 0 ? outputFormat.channelCount : 2
        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw CoordinatorError.noOutputAudioFormat
        }
        self.playbackFormat = playbackFormat
        engine.attach(realSpeechNode)
        engine.attach(fillerNode)
        engine.connect(realSpeechNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(fillerNode, to: engine.mainMixerNode, format: playbackFormat)
        realSpeechNode.volume = configuration.realSpeechVolume
        fillerNode.volume = configuration.fillerVolume
        try engine.start()
    }

    private func startEngineIfNeeded() {
        if engine.isRunning == false {
            do {
                try engine.start()
            } catch {
                print("""
                [TuringGapAudio] engine start failed
                  error: \(error.localizedDescription)
                """)
            }
        }
    }

    private func configureAudioSessionIfAvailable() throws {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try session.setActive(true)
        #endif
    }

    private func finishWaiterIfNeeded() {
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    private static func discoverFillerFiles(
        candidates: [String],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var urls: [URL] = []
        let bundle = Bundle.main
        let fileManager = FileManager.default

        for candidate in candidates {
            if let root = bundle.url(forResource: candidate, withExtension: nil) {
                urls.append(contentsOf: filesUnder(root, allowedExtensions: allowedExtensions))
            }

            let parts = candidate.split(separator: "/").map(String.init)
            if let name = parts.last {
                let subdirectory = parts.dropLast().joined(separator: "/")
                if let root = bundle.url(
                    forResource: name,
                    withExtension: nil,
                    subdirectory: subdirectory.isEmpty ? nil : subdirectory
                ) {
                    urls.append(contentsOf: filesUnder(root, allowedExtensions: allowedExtensions))
                }
            }
        }

        let uniqueURLs = Array(Set(urls))
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return uniqueURLs.flatMap { url in
            Array(repeating: url, count: fillerWeight(for: url))
        }
    }

    private static func fillerWeight(
        for url: URL
    ) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let separator = stem.lastIndex(of: "_") else {
            return 1
        }

        let suffixStart = stem.index(after: separator)
        guard suffixStart < stem.endIndex,
              let rawWeight = Int(stem[suffixStart...]) else {
            return 1
        }

        return min(max(rawWeight, 0), 10)
    }

    private static func filesUnder(
        _ root: URL,
        allowedExtensions: Set<String>
    ) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            result.append(url)
        }
        return result
    }
}
