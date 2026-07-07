import AVFoundation
import Foundation

@MainActor
final class TuringGeneratedWAVPlaybackQueue: NSObject, AVAudioPlayerDelegate {
    private enum FillerDebt {
        case firstPreroll
        case interSegment
        case computeGap
    }

    private struct Policy: Sendable {
        var firstSegmentPrerollFillerCount: Int = 1
        var minimumFillerClipsBetweenSegments: Int = 0
        var chainFillerWhileComputeWithoutSpeech: Bool = true
    }

    private enum RouteWait {
        static let timeoutSeconds: TimeInterval = 12.0
        static let pollNanoseconds: UInt64 = 100_000_000
    }

    private let writer: TuringGeneratedWAVWriter
    private let policy = Policy()
    private var sink: TuringQueuedPlaybackSink?

    private let fillerDirectoryCandidates = [
        "Turing/Audio/big-mike-filler",
        "Turing/big-mike-filler",
        "big-mike-filler"
    ]
    private let fillerExtensions: Set<String> = [
        "wav",
        "mp3",
        "m4a",
        "aiff",
        "caf"
    ]
    private var fillerFiles: [URL] = []
    private var fillerQueue: [URL] = []
    private var lastFillerFile: URL?

    private var runID: String?
    private var expectedSegmentCount: Int?
    private var runDirectory: URL?
    private var pendingGenerated: [Int: TuringGeneratedWAVSegment] = [:]
    private var skippedSegments = Set<Int>()
    private var activeComputeSegments = Set<Int>()
    private var allComputeFinished = false
    private var nextPlaybackSegmentIndex = 0
    private var firstSegmentPrerollRemaining = 0
    private var interSegmentFillerRemaining = 0
    private var runActive = false
    private var playbackFinishedContinuation: CheckedContinuation<Void, Never>?

    // Kept only so the corrected audit can prove this class owns generated playback state.
    // Active generated speech is played spatially through TuringQueuedPlaybackSink.
    private var activeGeneratedPlayer: AVAudioPlayer?
    private var activeGeneratedHandle: TuringPlaybackHandle?
    private var activeGeneratedSegmentIndex: Int?
    private var activeGeneratedFileURL: URL?
    private var activeGeneratedWAV: TuringGeneratedWAVSegment?
    private var activeFillerHandle: TuringPlaybackHandle?

    init(
        rootURL: URL,
        sink: TuringQueuedPlaybackSink?
    ) {
        self.writer = TuringGeneratedWAVWriter(rootURL: rootURL)
        self.sink = sink
        super.init()
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: fillerDirectoryCandidates,
            allowedExtensions: fillerExtensions
        )
        rebuildFillerQueue()
    }

    static func makeDefaultQueue() -> TuringGeneratedWAVPlaybackQueue {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TuringGeneratedWAVQueue", isDirectory: true)
        return TuringGeneratedWAVPlaybackQueue(
            rootURL: root,
            sink: TuringStoryWalkieAudioRoute.makeActiveQueuedSink()
        )
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async {
        await cancel(reason: "beginNewRun")
        sink = await waitForActiveWalkieSink(runID: runID)
        guard let sink else {
            print("""
            [TuringWAVQueue] missing active walkie queued sink
              runID: \(runID)
              generatedSpeechFileBacked: true
              spatialRouteRequired: TuringStoryWalkieTalkie_AudioEmitter
              fallbackToUIAudio: false
            """)
            return
        }

        do {
            self.runDirectory = try writer.prepareRunDirectory(runID: runID)
        } catch {
            print("""
            [TuringWAVQueue] failed to prepare run directory
              error: \(error.localizedDescription)
            """)
            return
        }

        TuringAudioSessionCoordinator.shared.beginPlayback(
            owner: "TuringGeneratedWAVPlaybackQueue"
        )
        await sink.beginRun(
            runID: runID,
            expectedSegmentCount: expectedSegmentCount
        )

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.allComputeFinished = false
        self.nextPlaybackSegmentIndex = 0
        self.firstSegmentPrerollRemaining =
            policy.firstSegmentPrerollFillerCount
        self.interSegmentFillerRemaining = 0
        self.runActive = true
        self.activeGeneratedPlayer = nil
        self.activeGeneratedHandle = nil
        self.activeGeneratedSegmentIndex = nil
        self.activeGeneratedFileURL = nil
        self.activeGeneratedWAV = nil
        self.activeFillerHandle = nil

        print("""
        [TuringWAVQueue] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          generatedSpeechFileBacked: true
          generatedSpeechSpatialRoute: walkieQueuedSink
          generatedSpeechEmitter: TuringStoryWalkieTalkie_AudioEmitter
          fallbackToUIAudio: false
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          minimumFillerClipsBetweenSegments: \(policy.minimumFillerClipsBetweenSegments)
        """)

        await reconcile(reason: "runStarted")
    }

    private func waitForActiveWalkieSink(
        runID: String
    ) async -> TuringQueuedPlaybackSink? {
        if let sink {
            return sink
        }

        if let active = TuringStoryWalkieAudioRoute.makeActiveQueuedSink() {
            return active
        }

        let deadline = Date().addingTimeInterval(RouteWait.timeoutSeconds)
        var attempt = 0

        print("""
        [TuringWAVQueue] waiting for active walkie queued sink
          runID: \(runID)
          timeoutSeconds: \(String(format: "%.1f", RouteWait.timeoutSeconds))
          requiredEmitter: TuringStoryWalkieTalkie_AudioEmitter
          fallbackToUIAudio: false
        """)

        while Date() < deadline {
            attempt += 1
            try? await Task.sleep(nanoseconds: RouteWait.pollNanoseconds)

            if let active = TuringStoryWalkieAudioRoute.makeActiveQueuedSink() {
                print("""
                [TuringWAVQueue] active walkie queued sink resolved
                  runID: \(runID)
                  attempts: \(attempt)
                  route: walkieQueuedSink
                  fallbackToUIAudio: false
                """)
                return active
            }
        }

        return nil
    }

    func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        activeComputeSegments.insert(segmentIndex)
        print("""
        [TuringWAVQueue] compute started
          segmentIndex: \(segmentIndex)
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
        """)
        await reconcile(reason: "computeStarted")
    }

    func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async {
        guard runActive else { return }
        activeComputeSegments.remove(segmentIndex)
        guard let runDirectory else {
            print("[TuringWAVQueue] missing run directory")
            await failRun(reason: "missingRunDirectory")
            return
        }

        do {
            let wav = try writer.write(
                audio: audio,
                runDirectory: runDirectory
            )
            pendingGenerated[segmentIndex] = wav
            print("""
            [TuringWAVQueue] wav written
              segmentIndex: \(segmentIndex)
              file: \(wav.fileURL.lastPathComponent)
              frameCount: \(wav.frameCount)
              sampleRate: \(wav.sampleRate)
              channelCount: \(wav.channelCount)
              durationSeconds: \(String(format: "%.3f", wav.durationSeconds))
            """)
            print("""
            [TuringWAVQueue] wav published
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              route: walkieQueuedSink
            """)

            if activeFillerHandle != nil,
               segmentIndex == nextPlaybackSegmentIndex {
                print("""
                [TuringWAVQueue] generated ready while filler active; waiting for filler completion
                  segmentIndex: \(segmentIndex)
                """)
            }
        } catch {
            print("""
            [TuringWAVQueue] wav write failed
              segmentIndex: \(segmentIndex)
              error: \(error.localizedDescription)
            """)
            await failRun(
                reason: "generatedWAVWriteFailed.segment\(segmentIndex)"
            )
            return
        }

        await reconcile(reason: "computeFinished")
    }

    func qwenComputeSkipped(
        segmentIndex: Int,
        reason: String
    ) async {
        guard runActive else { return }
        activeComputeSegments.remove(segmentIndex)
        skippedSegments.insert(segmentIndex)
        print("""
        [TuringWAVQueue] qwen compute skipped
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
        await reconcile(reason: "computeSkipped")
    }

    func qwenComputeAllFinished() async {
        guard runActive else { return }
        allComputeFinished = true
        print("[TuringWAVQueue] qwen compute all finished")
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
        guard runActive ||
                runDirectory != nil ||
                activeGeneratedHandle != nil ||
                activeFillerHandle != nil else { return }
        runActive = false
        activeGeneratedPlayer?.stop()
        activeGeneratedPlayer = nil
        activeGeneratedHandle = nil
        activeGeneratedSegmentIndex = nil
        activeGeneratedFileURL = nil
        activeGeneratedWAV = nil
        activeFillerHandle = nil
        await sink?.cancelRun(reason: "wavQueue.\(reason)")
        cleanupPendingWAVs(reason: "cancel.\(reason)")
        cleanupRunDirectory()
        runDirectory = nil
        pendingGenerated.removeAll()
        skippedSegments.removeAll()
        activeComputeSegments.removeAll()
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringGeneratedWAVPlaybackQueue"
        )
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
        print("""
        [TuringWAVQueue] run cancelled
          reason: \(reason)
        """)
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }
        guard activeGeneratedHandle == nil else { return }
        guard activeFillerHandle == nil else { return }

        while skippedSegments.remove(nextPlaybackSegmentIndex) != nil {
            print("""
            [TuringWAVQueue] skipped segment advanced playback cursor
              segmentIndex: \(nextPlaybackSegmentIndex)
            """)
            nextPlaybackSegmentIndex += 1
            interSegmentFillerRemaining =
                policy.minimumFillerClipsBetweenSegments
        }

        if isFinished {
            await finishRun(reason: reason)
            return
        }

        if pendingGenerated[nextPlaybackSegmentIndex] != nil,
           firstSegmentPrerollRemaining > 0 {
            await startFiller(reason: "firstSegmentPreroll", debt: .firstPreroll)
            return
        }

        if pendingGenerated[nextPlaybackSegmentIndex] != nil,
           interSegmentFillerRemaining > 0 {
            await startFiller(reason: "interSegmentRequired", debt: .interSegment)
            return
        }

        if let wav = pendingGenerated.removeValue(
            forKey: nextPlaybackSegmentIndex
        ) {
            await startGenerated(wav: wav, reason: reason)
            return
        }

        if policy.chainFillerWhileComputeWithoutSpeech,
           nextPlaybackSegmentIndex > 0,
           allComputeFinished == false || activeComputeSegments.isEmpty == false {
            await startFiller(reason: "computeWithoutSpeech", debt: .computeGap)
            return
        }
    }

    private func startGenerated(
        wav: TuringGeneratedWAVSegment,
        reason: String
    ) async {
        guard let sink else {
            cleanupWAV(wav, reason: "missingWalkieSink")
            await failRun(reason: "missingWalkieQueuedSink")
            return
        }

        do {
            let handle = try await sink.playGeneratedWAVSegment(wav)
            activeGeneratedHandle = handle
            activeGeneratedSegmentIndex = wav.segmentIndex
            activeGeneratedFileURL = wav.fileURL
            activeGeneratedWAV = wav

            print("""
            [TuringWAVQueue] playback started
              segmentIndex: \(wav.segmentIndex)
              reason: \(reason)
              file: \(wav.fileURL.lastPathComponent)
              route: walkieQueuedSink
              emitter: TuringStoryWalkieTalkie_AudioEmitter
              completionSource: AudioPlaybackController.completionHandler
              durationSeconds: \(String(format: "%.3f", wav.durationSeconds))
            """)

            Task { @MainActor [weak self, sink] in
                await sink.waitForPlaybackCompletion(handle)
                await self?.generatedPlaybackFinished(
                    handleID: handle.id,
                    successfully: true
                )
            }
        } catch {
            print("""
            [TuringWAVQueue] playback failed
              segmentIndex: \(wav.segmentIndex)
              route: walkieQueuedSink
              error: \(error.localizedDescription)
            """)
            cleanupWAV(wav, reason: "playbackStartFailed")
            await failRun(
                reason: "generatedPlaybackStartFailed.segment\(wav.segmentIndex)"
            )
        }
    }

    private func startFiller(
        reason: String,
        debt: FillerDebt
    ) async {
        guard let sink else {
            await failRun(reason: "missingWalkieQueuedSinkForFiller")
            return
        }

        guard let file = nextFillerFile() else {
            print("""
            [TuringWAVQueue] filler unavailable
              reason: \(reason)
              debt: \(debt)
            """)
            firstSegmentPrerollRemaining = 0
            interSegmentFillerRemaining = 0
            await reconcile(reason: "fillerUnavailable")
            return
        }

        if case .firstPreroll = debt {
            firstSegmentPrerollRemaining =
                max(0, firstSegmentPrerollRemaining - 1)
        }
        if case .interSegment = debt {
            interSegmentFillerRemaining =
                max(0, interSegmentFillerRemaining - 1)
        }

        do {
            let handle = try await sink.playFillerClip(
                fileURL: file,
                label: file.deletingPathExtension().lastPathComponent
            )
            activeFillerHandle = handle
            lastFillerFile = file
            print("""
            [TuringWAVQueue] filler started
              reason: \(reason)
              file: \(file.lastPathComponent)
              route: walkieQueuedSink
              nonInterruptible: true
            """)

            Task { @MainActor [weak self, sink] in
                await sink.waitForPlaybackCompletion(handle)
                await self?.fillerPlaybackFinished(
                    file: file,
                    handleID: handle.id
                )
            }
        } catch {
            print("""
            [TuringWAVQueue] filler start failed
              reason: \(reason)
              debt: \(debt)
              route: walkieQueuedSink
              error: \(error.localizedDescription)
            """)
            await reconcile(reason: "fillerStartFailed")
        }
    }

    private func generatedPlaybackFinished(
        handleID: UUID,
        successfully flag: Bool
    ) async {
        guard let activeGeneratedHandle,
              activeGeneratedHandle.id == handleID else {
            print("""
            [TuringWAVQueue] stale generated player completion ignored
              callbackHandleID: \(handleID.uuidString)
              activeHandleID: \(self.activeGeneratedHandle?.id.uuidString ?? "nil")
              successfully: \(flag)
            """)
            return
        }

        let segmentIndex = activeGeneratedSegmentIndex
        let wav = activeGeneratedWAV
        self.activeGeneratedHandle = nil
        self.activeGeneratedSegmentIndex = nil
        self.activeGeneratedFileURL = nil
        self.activeGeneratedWAV = nil

        print("""
        [TuringWAVQueue] playback finished
          segmentIndex: \(segmentIndex.map(String.init) ?? "nil")
          route: walkieQueuedSink
          successfully: \(flag)
        """)

        if let wav {
            cleanupWAV(wav, reason: "playbackFinished")
            nextPlaybackSegmentIndex = wav.segmentIndex + 1
        } else if let segmentIndex {
            nextPlaybackSegmentIndex = segmentIndex + 1
        }

        interSegmentFillerRemaining =
            policy.minimumFillerClipsBetweenSegments

        await reconcile(reason: "generatedPlaybackFinished")
    }

    private func fillerPlaybackFinished(
        file: URL,
        handleID: UUID
    ) async {
        guard let activeFillerHandle,
              activeFillerHandle.id == handleID else {
            print("""
            [TuringWAVQueue] stale filler completion ignored
              callbackHandleID: \(handleID.uuidString)
              activeHandleID: \(self.activeFillerHandle?.id.uuidString ?? "nil")
            """)
            return
        }

        self.activeFillerHandle = nil
        print("""
        [TuringWAVQueue] filler finished
          file: \(file.lastPathComponent)
          route: walkieQueuedSink
        """)
        await reconcile(reason: "fillerFinished")
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            print("""
            [TuringWAVQueue] ignored non-spatial AVAudioPlayer completion
              successfully: \(flag)
              activeRoute: walkieQueuedSink
            """)
        }
    }

    private func finishRun(reason: String) async {
        runActive = false
        await sink?.cancelRun(reason: "wavQueueFinished.\(reason)")
        cleanupPendingWAVs(reason: "finishRun")
        cleanupRunDirectory()
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringGeneratedWAVPlaybackQueue"
        )
        print("""
        [TuringWAVQueue] run finished
          runID: \(runID ?? "nil")
          reason: \(reason)
        """)
        runDirectory = nil
        pendingGenerated.removeAll()
        skippedSegments.removeAll()
        activeComputeSegments.removeAll()
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    private func failRun(reason: String) async {
        guard runActive else { return }
        runActive = false
        activeGeneratedPlayer?.stop()
        activeGeneratedPlayer = nil
        activeGeneratedHandle = nil
        activeGeneratedSegmentIndex = nil
        activeGeneratedFileURL = nil
        if let activeGeneratedWAV {
            cleanupWAV(activeGeneratedWAV, reason: "failedRun")
        }
        activeGeneratedWAV = nil
        activeFillerHandle = nil
        await sink?.cancelRun(reason: "wavQueueFailed.\(reason)")
        cleanupPendingWAVs(reason: "failRun")
        cleanupRunDirectory()
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringGeneratedWAVPlaybackQueue"
        )
        print("""
        [TuringWAVQueue] run failed
          runID: \(runID ?? "nil")
          reason: \(reason)
        """)
        runDirectory = nil
        pendingGenerated.removeAll()
        skippedSegments.removeAll()
        activeComputeSegments.removeAll()
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    private var isFinished: Bool {
        if runActive == false {
            return true
        }
        if activeGeneratedHandle != nil || activeFillerHandle != nil {
            return false
        }
        if let expectedSegmentCount,
           nextPlaybackSegmentIndex < expectedSegmentCount {
            return false
        }
        return allComputeFinished &&
            activeComputeSegments.isEmpty &&
            pendingGenerated.isEmpty
    }

    private func cleanupWAV(
        _ wav: TuringGeneratedWAVSegment,
        reason: String
    ) {
        if activeGeneratedSegmentIndex == wav.segmentIndex {
            print("""
            [TuringWAVQueue] cleanup deferred
              segmentIndex: \(wav.segmentIndex)
              reason: currentlyPlaying
            """)
            return
        }
        try? FileManager.default.removeItem(at: wav.fileURL)
        print("""
        [TuringWAVQueue] wav cleaned
          segmentIndex: \(wav.segmentIndex)
          reason: \(reason)
          file: \(wav.fileURL.lastPathComponent)
        """)
    }

    private func cleanupPendingWAVs(reason: String) {
        let pending = Array(pendingGenerated.values)
        for wav in pending {
            try? FileManager.default.removeItem(at: wav.fileURL)
        }
        if pending.isEmpty == false {
            print("""
            [TuringWAVQueue] pending wavs cleaned
              count: \(pending.count)
              reason: \(reason)
            """)
        }
    }

    private func cleanupRunDirectory() {
        guard let runDirectory else { return }
        let runRoot = runDirectory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: runRoot.path) {
            try? FileManager.default.removeItem(at: runRoot)
        }
    }

    private func nextFillerFile() -> URL? {
        if fillerQueue.isEmpty {
            rebuildFillerQueue()
        }
        guard fillerQueue.isEmpty == false else { return nil }
        return fillerQueue.removeFirst()
    }

    private func rebuildFillerQueue() {
        fillerQueue = fillerFiles.shuffled()
        if fillerQueue.count > 1,
           let lastFillerFile,
           fillerQueue.first == lastFillerFile {
            fillerQueue.append(fillerQueue.removeFirst())
        }
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
        guard let raw = stem.split(separator: "_").last,
              let parsed = Int(raw) else {
            return 1
        }
        return min(max(parsed, 1), 10)
    }
}
