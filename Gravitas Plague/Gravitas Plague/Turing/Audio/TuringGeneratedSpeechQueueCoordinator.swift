import Foundation

@MainActor
final class TuringGeneratedSpeechQueueCoordinator {
    struct Policy: Sendable {
        var firstSegmentPrerollFillerCount: Int
        var minimumFillerClipsBetweenSegments: Int
        var chainFillerWhileComputeWithoutSpeech: Bool
        var deadAirAfterFillerEnabled: Bool
        var deadAirMinSeconds: Double
        var deadAirMaxSeconds: Double
        var fillerDirectoryCandidates: [String]
        var fillerExtensions: Set<String>
        var avoidImmediateFillerRepeat: Bool

        static let bigMikeDefault = Policy(
            firstSegmentPrerollFillerCount: 1,
            minimumFillerClipsBetweenSegments: 0,
            chainFillerWhileComputeWithoutSpeech: true,
            deadAirAfterFillerEnabled: true,
            deadAirMinSeconds: 0.5,
            deadAirMaxSeconds: 4.0,
            fillerDirectoryCandidates: [
                "Turing/Audio/big-mike-filler",
                "Turing/big-mike-filler",
                "big-mike-filler"
            ],
            fillerExtensions: ["wav", "mp3", "m4a", "aiff", "caf"],
            avoidImmediateFillerRepeat: true
        )
    }

    private enum PlaybackState {
        case idle
        case playingGenerated(segmentIndex: Int, handleID: UUID)
        case playingFiller(handleID: UUID)
        case deadAir
        case cancelled
    }

    private enum FillerDebt {
        case firstPreroll
        case interSegment
        case computeGap
    }

    private let sink: TuringQueuedPlaybackSink
    private let policy: Policy
    private var fillerFiles: [URL]
    private var fillerQueue: [URL] = []
    private var lastFillerFile: URL?

    private var runID: String?
    private var expectedSegmentCount: Int?
    private var nextPlaybackSegmentIndex = 0
    private var pendingGenerated: [Int: TuringComputeGapGeneratedAudio] = [:]
    private var skippedSegments = Set<Int>()
    private var activeComputeSegments = Set<Int>()
    private var allComputeFinished = false
    private var state: PlaybackState = .idle
    private var firstSegmentPrerollRemaining = 0
    private var interSegmentFillerRemaining = 0
    private var deadAirTask: Task<Void, Never>?
    private var playbackFinishedContinuation: CheckedContinuation<Void, Never>?

    init(
        sink: TuringQueuedPlaybackSink,
        policy: Policy = .bigMikeDefault
    ) {
        self.sink = sink
        self.policy = policy
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: policy.fillerDirectoryCandidates,
            allowedExtensions: policy.fillerExtensions
        )

        print("""
        [TuringPlaybackQueue] initialized
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          minimumFillerClipsBetweenSegments: \(policy.minimumFillerClipsBetweenSegments)
          deadAirAfterFiller: \(policy.deadAirAfterFillerEnabled)
          deadAirSeconds: \(String(format: "%.2f", policy.deadAirMinSeconds))...\(String(format: "%.2f", policy.deadAirMaxSeconds))
        """)
    }

    static func makeBigMikeCoordinator(
        policy: Policy = .bigMikeDefault
    ) throws -> TuringGeneratedSpeechQueueCoordinator {
        throw TuringRuntimeError.playbackFailed(
            "TuringGeneratedSpeechQueueCoordinator is disabled for generated speech. Use TuringSerialWAVFillerPlaybackQueue."
        )
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async {
        TuringAudioSessionCoordinator.shared.beginPlayback(
            owner: "TuringGeneratedSpeechQueue"
        )

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.nextPlaybackSegmentIndex = 0
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.allComputeFinished = false
        self.state = .idle
        self.firstSegmentPrerollRemaining = max(
            0,
            policy.firstSegmentPrerollFillerCount
        )
        self.interSegmentFillerRemaining = 0
        self.deadAirTask?.cancel()
        self.deadAirTask = nil
        self.playbackFinishedContinuation = nil
        await sink.beginRun(
            runID: runID,
            expectedSegmentCount: expectedSegmentCount
        )

        print("""
        [TuringPlaybackQueue] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          minimumFillerClipsBetweenSegments: \(policy.minimumFillerClipsBetweenSegments)
          deadAirAfterFiller: \(policy.deadAirAfterFillerEnabled)
          deadAirSeconds: \(String(format: "%.2f", policy.deadAirMinSeconds))...\(String(format: "%.2f", policy.deadAirMaxSeconds))
        """)

        await reconcile(reason: "runStarted")
    }

    func qwenComputeStarted(segmentIndex: Int) async {
        if case .cancelled = state {
            return
        }

        activeComputeSegments.insert(segmentIndex)
        print("""
        [TuringPlaybackQueue] qwen compute started
          segmentIndex: \(segmentIndex)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          activeComputeSegments: \(activeComputeSegments.sorted().map(String.init).joined(separator: ","))
        """)
        await reconcile(reason: "computeStarted")
    }

    func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async {
        if case .cancelled = state {
            return
        }

        activeComputeSegments.remove(segmentIndex)

        guard segmentIndex >= nextPlaybackSegmentIndex else {
            print("""
            [TuringPlaybackQueue] stale generated segment ignored
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }

        pendingGenerated[segmentIndex] = audio

        print("""
        [TuringPlaybackQueue] compute finished
          segmentIndex: \(segmentIndex)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          state: \(stateLogName)
          pendingGenerated: \(pendingGenerated.keys.sorted().map(String.init).joined(separator: ","))
        """)

        if case .deadAir = state,
           pendingGenerated[nextPlaybackSegmentIndex] != nil {
            stopDeadAir(reason: "nextGeneratedReady")
        }

        await reconcile(reason: "computeFinished")
    }

    func qwenComputeSkipped(
        segmentIndex: Int,
        reason: String
    ) async {
        if case .cancelled = state {
            return
        }

        activeComputeSegments.remove(segmentIndex)
        skippedSegments.insert(segmentIndex)

        print("""
        [TuringPlaybackQueue] qwen compute skipped
          segmentIndex: \(segmentIndex)
          reason: \(reason)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)

        if case .deadAir = state,
           skippedSegments.contains(nextPlaybackSegmentIndex) {
            stopDeadAir(reason: "nextSegmentSkipped")
        }

        await reconcile(reason: "computeSkipped")
    }

    func qwenComputeAllFinished() async {
        allComputeFinished = true
        activeComputeSegments.removeAll(keepingCapacity: true)
        print("[TuringPlaybackQueue] qwen compute all finished")
        await reconcile(reason: "computeAllFinished")
    }

    func waitUntilPlaybackFinished() async {
        if isFinished {
            return
        }

        await withCheckedContinuation { continuation in
            playbackFinishedContinuation = continuation
        }
    }

    func cancel(reason: String) async {
        state = .cancelled
        deadAirTask?.cancel()
        deadAirTask = nil
        pendingGenerated.removeAll(keepingCapacity: false)
        activeComputeSegments.removeAll(keepingCapacity: false)
        skippedSegments.removeAll(keepingCapacity: false)
        await sink.cancelRun(reason: reason)
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringGeneratedSpeechQueue"
        )
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil

        print("""
        [TuringPlaybackQueue] run cancelled
          reason: \(reason)
        """)
    }

    private func reconcile(reason: String) async {
        guard case .cancelled = state else {
            advanceSkippedSegmentsIfNeeded()

            if isFinished {
                await finishRun(reason: reason)
                return
            }

            if case .playingGenerated = state {
                return
            }

            if case .playingFiller = state {
                return
            }

            if case .deadAir = state {
                if pendingGenerated[nextPlaybackSegmentIndex] != nil ||
                    skippedSegments.contains(nextPlaybackSegmentIndex) {
                    stopDeadAir(reason: "nextGeneratedReady")
                } else {
                    return
                }
            }

            if let next = pendingGenerated[nextPlaybackSegmentIndex] {
                if firstSegmentPrerollRemaining > 0 {
                    await playFiller(
                        reason: "firstSegmentPreroll",
                        debt: .firstPreroll
                    )
                    return
                }

                if interSegmentFillerRemaining > 0 {
                    await playFiller(
                        reason: "interSegmentRequired",
                        debt: .interSegment
                    )
                    return
                }

                await playGenerated(audio: next)
                return
            }

            if allComputeFinished == false ||
                activeComputeSegments.isEmpty == false {
                if nextPlaybackSegmentIndex == 0,
                   firstSegmentPrerollRemaining > 0 {
                    print("""
                    [TuringPlaybackQueue] waiting for first generated segment
                      fillerSuppressedUntilFirstSegmentReady: true
                      nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
                    """)
                    return
                }

                if policy.chainFillerWhileComputeWithoutSpeech {
                    await playFiller(
                        reason: "computeWithoutSpeech",
                        debt: .computeGap
                    )
                }
                return
            }

            await finishRun(reason: reason)
            return
        }
    }

    private func playGenerated(
        audio: TuringComputeGapGeneratedAudio
    ) async {
        guard audio.segmentIndex == nextPlaybackSegmentIndex else {
            print("""
            [TuringPlaybackQueue] out-of-order generated playback prevented
              segmentIndex: \(audio.segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }

        pendingGenerated.removeValue(forKey: audio.segmentIndex)

        skippedSegments.insert(audio.segmentIndex)
        print("""
        [TuringPlaybackQueue] legacy generated playback blocked
          segmentIndex: \(audio.segmentIndex)
          expectedOwner: TuringSerialWAVFillerPlaybackQueue
        """)
        await reconcile(reason: "legacyGeneratedPlaybackBlocked")
    }

    private func generatedPlaybackFinished(
        segmentIndex: Int,
        handleID: UUID
    ) async {
        guard case .playingGenerated(
            let activeSegmentIndex,
            let activeHandleID
        ) = state,
              activeSegmentIndex == segmentIndex,
              activeHandleID == handleID else {
            print("""
            [TuringPlaybackQueue] stale generated playback completion ignored
              callbackSegmentIndex: \(segmentIndex)
              callbackHandleID: \(handleID.uuidString)
              state: \(stateLogName)
            """)
            return
        }

        nextPlaybackSegmentIndex += 1
        interSegmentFillerRemaining = 0
        state = .idle

        print("""
        [TuringPlaybackQueue] generated playback finished
          segmentIndex: \(segmentIndex)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)

        await reconcile(reason: "generatedFinished")
    }

    private func playFiller(
        reason: String,
        debt: FillerDebt
    ) async {
        guard case .idle = state else { return }
        guard let file = nextFillerFile() else {
            print("""
            [TuringPlaybackQueue] filler unavailable
              reason: \(reason)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            if case .firstPreroll = debt {
                firstSegmentPrerollRemaining = 0
            }
            if case .interSegment = debt {
                interSegmentFillerRemaining = 0
            }
            await reconcile(reason: "fillerUnavailable")
            return
        }

        if case .firstPreroll = debt {
            firstSegmentPrerollRemaining = max(0, firstSegmentPrerollRemaining - 1)
        }
        if case .interSegment = debt {
            interSegmentFillerRemaining = max(0, interSegmentFillerRemaining - 1)
        }

        do {
            let handle = try await sink.playFillerClip(
                fileURL: file,
                label: file.deletingPathExtension().lastPathComponent
            )
            state = .playingFiller(handleID: handle.id)
            lastFillerFile = file

            print("""
            [TuringPlaybackQueue] filler started
              reason: \(reason)
              file: \(file.lastPathComponent)
              handleID: \(handle.id.uuidString)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              nonInterruptible: true
            """)

            Task { @MainActor [weak self] in
                await self?.sink.waitForPlaybackCompletion(handle)
                await self?.fillerPlaybackFinished(
                    file: file,
                    handleID: handle.id
                )
            }
        } catch {
            print("""
            [TuringPlaybackQueue] filler start failed
              reason: \(reason)
              file: \(file.lastPathComponent)
              error: \(error.localizedDescription)
            """)
            state = .idle
            await reconcile(reason: "fillerStartFailed")
        }
    }

    private func fillerPlaybackFinished(
        file: URL,
        handleID: UUID
    ) async {
        guard case .playingFiller(let activeHandleID) = state,
              activeHandleID == handleID else {
            print("""
            [TuringPlaybackQueue] stale filler completion ignored
              file: \(file.lastPathComponent)
              callbackHandleID: \(handleID.uuidString)
              state: \(stateLogName)
            """)
            return
        }

        state = .idle

        print("""
        [TuringPlaybackQueue] filler clip finished
          file: \(file.lastPathComponent)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)

        if pendingGenerated[nextPlaybackSegmentIndex] == nil,
           allComputeFinished == false || activeComputeSegments.isEmpty == false,
           policy.deadAirAfterFillerEnabled {
            startDeadAirAfterFiller(afterClip: file)
            return
        }

        await reconcile(reason: "fillerFinished")
    }

    private func startDeadAirAfterFiller(afterClip clipURL: URL) {
        guard case .idle = state else { return }

        state = .deadAir
        let minSeconds = min(policy.deadAirMinSeconds, policy.deadAirMaxSeconds)
        let maxSeconds = max(policy.deadAirMinSeconds, policy.deadAirMaxSeconds)
        let seconds = Double.random(in: minSeconds...maxSeconds)

        print("""
        [TuringPlaybackQueue] dead air started
          afterClip: \(clipURL.lastPathComponent)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          seconds: \(String(format: "%.2f", seconds))
          interruptibleByGeneratedSpeech: true
        """)

        deadAirTask?.cancel()
        deadAirTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(seconds * 1_000_000_000)
            )
            await self?.deadAirFinished()
        }
    }

    private func deadAirFinished() async {
        guard case .deadAir = state else { return }
        deadAirTask = nil
        state = .idle

        print("""
        [TuringPlaybackQueue] dead air finished
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)

        await reconcile(reason: "deadAirFinished")
    }

    private func stopDeadAir(reason: String) {
        guard case .deadAir = state else { return }
        deadAirTask?.cancel()
        deadAirTask = nil
        state = .idle

        print("""
        [TuringPlaybackQueue] dead air stopped
          reason: \(reason)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)
    }

    private func advanceSkippedSegmentsIfNeeded() {
        while skippedSegments.contains(nextPlaybackSegmentIndex) {
            skippedSegments.remove(nextPlaybackSegmentIndex)
            print("""
            [TuringPlaybackQueue] skipped segment advanced playback cursor
              segmentIndex: \(nextPlaybackSegmentIndex)
            """)
            nextPlaybackSegmentIndex += 1
            interSegmentFillerRemaining = max(
                0,
                policy.minimumFillerClipsBetweenSegments
            )
        }
    }

    private func finishRun(reason: String) async {
        guard isFinished else { return }
        state = .idle
        deadAirTask?.cancel()
        deadAirTask = nil
        await sink.cancelRun(reason: "finished.\(reason)")
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringGeneratedSpeechQueue"
        )
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil

        print("""
        [TuringPlaybackQueue] run finished
          reason: \(reason)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)
    }

    private var isFinished: Bool {
        if case .cancelled = state {
            return true
        }

        if case .playingGenerated = state {
            return false
        }
        if case .playingFiller = state {
            return false
        }
        if case .deadAir = state {
            return false
        }

        if let expectedSegmentCount {
            return nextPlaybackSegmentIndex >= expectedSegmentCount &&
                pendingGenerated.isEmpty &&
                activeComputeSegments.isEmpty
        }

        return allComputeFinished &&
            pendingGenerated.isEmpty &&
            activeComputeSegments.isEmpty
    }

    private var stateLogName: String {
        switch state {
        case .idle:
            return "idle"
        case .playingGenerated(let segmentIndex, _):
            return "playingGenerated.segment\(segmentIndex)"
        case .playingFiller:
            return "playingFiller"
        case .deadAir:
            return "deadAir"
        case .cancelled:
            return "cancelled"
        }
    }

    private func nextFillerFile() -> URL? {
        if fillerQueue.isEmpty {
            fillerQueue = fillerFiles.shuffled()
            if policy.avoidImmediateFillerRepeat,
               fillerQueue.count > 1,
               let lastFillerFile,
               fillerQueue.first == lastFillerFile {
                fillerQueue.append(fillerQueue.removeFirst())
            }
        }

        guard fillerQueue.isEmpty == false else {
            return nil
        }
        return fillerQueue.removeFirst()
    }

    private static func discoverFillerFiles(
        candidates: [String],
        allowedExtensions: Set<String>
    ) -> [URL] {
        var weighted: [URL] = []

        for candidate in candidates {
            guard let directory = Bundle.main.url(
                forResource: candidate,
                withExtension: nil
            ) else {
                continue
            }

            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard allowedExtensions.contains(file.pathExtension.lowercased()) else {
                    continue
                }
                weighted.append(
                    contentsOf: Array(
                        repeating: file,
                        count: fillerWeight(for: file)
                    )
                )
            }
        }

        return weighted
    }

    private static func fillerWeight(for file: URL) -> Int {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let suffix = stem.split(separator: "_").last,
              let weight = Int(suffix) else {
            return 1
        }

        return min(10, max(1, weight))
    }
}
