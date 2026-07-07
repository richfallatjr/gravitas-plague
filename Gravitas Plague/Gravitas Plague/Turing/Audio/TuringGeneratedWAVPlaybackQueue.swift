import AVFoundation
import Foundation

@MainActor
final class TuringGeneratedWAVPlaybackQueue: NSObject, AVAudioPlayerDelegate {
    private enum RouteWait {
        static let timeoutSeconds: TimeInterval = 12.0
        static let pollNanoseconds: UInt64 = 100_000_000
    }

    private let writer: TuringGeneratedWAVWriter
    private var sink: TuringQueuedPlaybackSink?
    private let sideLane = TuringFillerSideLaneCoordinator()

    private var runID: String?
    private var expectedSegmentCount: Int?
    private var runDirectory: URL?
    private var pendingGenerated: [Int: TuringGeneratedWAVSegment] = [:]
    private var skippedSegments = Set<Int>()
    private var activeComputeSegments = Set<Int>()
    private var allComputeFinished = false
    private var nextPlaybackSegmentIndex = 0
    private var runActive = false
    private var playbackFinishedContinuations: [CheckedContinuation<Void, Never>] = []

    private var activeGeneratedHandle: TuringPlaybackHandle?
    private var activeGeneratedSegmentIndex: Int?
    private var activeGeneratedWAV: TuringGeneratedWAVSegment?
    // Retained fallback slot for AVAudioPlayerDelegate-based playback audits.
    // The active Story route plays generated WAVs through the walkie queued sink.
    private var activeGeneratedPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?

    init(
        rootURL: URL,
        sink: TuringQueuedPlaybackSink?
    ) {
        self.writer = TuringGeneratedWAVWriter(rootURL: rootURL)
        self.sink = sink
        super.init()
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
        await sideLane.beginRun(
            runID: runID,
            expectedSegmentCount: expectedSegmentCount,
            sink: sink,
            onPlaybackMayProceed: { [weak self] in
                await self?.sideLanePlaybackMayProceed()
            }
        )

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.allComputeFinished = false
        self.nextPlaybackSegmentIndex = 0
        self.runActive = true
        self.activeGeneratedHandle = nil
        self.activeGeneratedSegmentIndex = nil
        self.activeGeneratedWAV = nil
        self.activeGeneratedPlayer = nil
        self.playbackTask?.cancel()
        self.playbackTask = nil
        await sideLane.updateNextRequiredSegmentIndex(nextPlaybackSegmentIndex)

        print("""
        [TuringWAVQueue] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          generatedSpeechFileBacked: true
          generatedSpeechSpatialRoute: walkieQueuedSink
          generatedSpeechEmitter: TuringStoryWalkieTalkie_AudioEmitter
          fallbackToUIAudio: false
          fillerOwner: TuringFillerSideLane
        """)

        await reconcile(reason: "runStarted")
    }

    private func waitForActiveWalkieSink(
        runID: String
    ) async -> TuringQueuedPlaybackSink? {
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

        print("""
        [TuringWAVQueue] active walkie queued sink unavailable
          runID: \(runID)
          waitedSeconds: \(String(format: "%.1f", RouteWait.timeoutSeconds))
          fallbackToUIAudio: false
          cachedSinkFallback: false
        """)
        return nil
    }

    func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        guard segmentIndex >= nextPlaybackSegmentIndex else {
            print("""
            [TuringWAVQueue] stale compute start ignored
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }
        if let expectedSegmentCount,
           segmentIndex >= expectedSegmentCount {
            print("""
            [TuringWAVQueue] out-of-range compute start ignored
              segmentIndex: \(segmentIndex)
              expectedSegmentCount: \(expectedSegmentCount)
            """)
            return
        }
        activeComputeSegments.insert(segmentIndex)
        await sideLane.qwenComputeStarted(segmentIndex: segmentIndex)
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
        guard segmentIndex >= nextPlaybackSegmentIndex else {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "staleAfterPlaybackCursor"
            )
            print("""
            [TuringWAVQueue] stale generated segment discarded before wav write
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              activeGeneratedSegmentIndex: \(activeGeneratedSegmentIndex.map(String.init) ?? "nil")
            """)
            return
        }
        if let expectedSegmentCount,
           segmentIndex >= expectedSegmentCount {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "outOfRangeAfterExpectedCount"
            )
            print("""
            [TuringWAVQueue] out-of-range generated segment discarded before wav write
              segmentIndex: \(segmentIndex)
              expectedSegmentCount: \(expectedSegmentCount)
            """)
            return
        }
        guard activeGeneratedSegmentIndex != segmentIndex else {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "duplicateAlreadyPlaying"
            )
            print("""
            [TuringWAVQueue] duplicate generated segment discarded because it is already playing
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }
        guard pendingGenerated[segmentIndex] == nil else {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "duplicateAlreadyPending"
            )
            print("""
            [TuringWAVQueue] duplicate generated segment discarded because it is already pending
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            return
        }
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
            await sideLane.generatedWAVPublished(segmentIndex: segmentIndex)
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
        guard segmentIndex >= nextPlaybackSegmentIndex else {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "staleSkippedSegment.\(reason)"
            )
            print("""
            [TuringWAVQueue] stale qwen compute skip ignored
              segmentIndex: \(segmentIndex)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
              reason: \(reason)
            """)
            return
        }
        if let expectedSegmentCount,
           segmentIndex >= expectedSegmentCount {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "outOfRangeSkippedSegment.\(reason)"
            )
            print("""
            [TuringWAVQueue] out-of-range qwen compute skip ignored
              segmentIndex: \(segmentIndex)
              expectedSegmentCount: \(expectedSegmentCount)
              reason: \(reason)
            """)
            return
        }
        guard activeGeneratedSegmentIndex != segmentIndex else {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "skipIgnoredAlreadyPlaying.\(reason)"
            )
            print("""
            [TuringWAVQueue] qwen compute skip ignored because segment is already playing
              segmentIndex: \(segmentIndex)
              reason: \(reason)
            """)
            return
        }
        guard pendingGenerated[segmentIndex] == nil else {
            await sideLane.qwenComputeSkipped(
                segmentIndex: segmentIndex,
                reason: "skipIgnoredAlreadyPending.\(reason)"
            )
            print("""
            [TuringWAVQueue] qwen compute skip ignored because generated wav is already pending
              segmentIndex: \(segmentIndex)
              reason: \(reason)
            """)
            return
        }
        skippedSegments.insert(segmentIndex)
        await sideLane.qwenComputeSkipped(
            segmentIndex: segmentIndex,
            reason: reason
        )
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
        await sideLane.qwenComputeAllFinished()
        print("[TuringWAVQueue] qwen compute all finished")
        await reconcile(reason: "computeAllFinished")
    }

    func waitUntilPlaybackFinished() async {
        if isFinished {
            return
        }

        await withCheckedContinuation { continuation in
            playbackFinishedContinuations.append(continuation)
        }
    }

    func cancel(reason: String) async {
        guard runActive ||
                runDirectory != nil ||
                activeGeneratedHandle != nil ||
                playbackTask != nil ||
                playbackFinishedContinuations.isEmpty == false else { return }
        runActive = false
        playbackTask?.cancel()
        playbackTask = nil
        activeGeneratedPlayer?.stop()
        activeGeneratedPlayer = nil
        activeGeneratedHandle = nil
        activeGeneratedSegmentIndex = nil
        activeGeneratedWAV = nil
        await sideLane.runCancelled(reason: "wavQueue.\(reason)")
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
        resumePlaybackFinishedContinuations()
        print("""
        [TuringWAVQueue] run cancelled
          reason: \(reason)
        """)
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }
        guard activeGeneratedHandle == nil,
              playbackTask == nil else { return }

        cleanupStalePendingGenerated(reason: "reconcile.\(reason)")

        while skippedSegments.remove(nextPlaybackSegmentIndex) != nil {
            print("""
            [TuringWAVQueue] skipped segment advanced playback cursor
              segmentIndex: \(nextPlaybackSegmentIndex)
            """)
            nextPlaybackSegmentIndex += 1
            cleanupStalePendingGenerated(reason: "skipAdvance.\(reason)")
            await sideLane.updateNextRequiredSegmentIndex(
                nextPlaybackSegmentIndex
            )
        }

        if isFinished {
            await finishRun(reason: reason)
            return
        }

        guard sideLane.shouldDeferGeneratedPlayback == false else {
            if pendingGenerated[nextPlaybackSegmentIndex] != nil {
                print("""
                [TuringWAVQueue] generated ready while filler active; waiting for filler completion
                  segmentIndex: \(nextPlaybackSegmentIndex)
                  fillerOwner: TuringFillerSideLane
                """)
            }
            return
        }

        if let wav = pendingGenerated.removeValue(
            forKey: nextPlaybackSegmentIndex
        ) {
            await startGenerated(wav: wav, reason: reason)
        }
    }

    private func sideLanePlaybackMayProceed() async {
        await reconcile(reason: "sideLanePlaybackMayProceed")
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
            activeGeneratedWAV = wav
            await sideLane.generatedPlaybackStarted(segmentIndex: wav.segmentIndex)

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

            playbackTask = Task { @MainActor [weak self, sink] in
                await sink.waitForPlaybackCompletion(handle)
                guard Task.isCancelled == false else { return }
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
        self.activeGeneratedWAV = nil
        self.activeGeneratedPlayer = nil
        self.playbackTask = nil

        print("""
        [TuringWAVQueue] playback finished
          segmentIndex: \(segmentIndex.map(String.init) ?? "nil")
          route: walkieQueuedSink
          successfully: \(flag)
        """)

        if let wav {
            cleanupWAV(wav, reason: "playbackFinished")
            nextPlaybackSegmentIndex = wav.segmentIndex + 1
            await sideLane.updateNextRequiredSegmentIndex(
                nextPlaybackSegmentIndex
            )
            await sideLane.generatedPlaybackFinished(
                segmentIndex: wav.segmentIndex
            )
        } else if let segmentIndex {
            nextPlaybackSegmentIndex = segmentIndex + 1
            await sideLane.updateNextRequiredSegmentIndex(
                nextPlaybackSegmentIndex
            )
            await sideLane.generatedPlaybackFinished(
                segmentIndex: segmentIndex
            )
        }

        await reconcile(reason: "generatedPlaybackFinished")
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
        await sideLane.runCancelled(reason: "wavQueueFinished.\(reason)")
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
        resumePlaybackFinishedContinuations()
    }

    private func failRun(reason: String) async {
        guard runActive else { return }
        runActive = false
        playbackTask?.cancel()
        playbackTask = nil
        activeGeneratedPlayer?.stop()
        activeGeneratedPlayer = nil
        activeGeneratedHandle = nil
        activeGeneratedSegmentIndex = nil
        if let activeGeneratedWAV {
            cleanupWAV(activeGeneratedWAV, reason: "failedRun")
        }
        activeGeneratedWAV = nil
        await sideLane.runCancelled(reason: "wavQueueFailed.\(reason)")
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
        resumePlaybackFinishedContinuations()
    }

    private var isFinished: Bool {
        if runActive == false {
            return true
        }
        if activeGeneratedHandle != nil || playbackTask != nil {
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

    private func resumePlaybackFinishedContinuations() {
        let continuations = playbackFinishedContinuations
        playbackFinishedContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
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

    private func cleanupStalePendingGenerated(reason: String) {
        let staleKeys = pendingGenerated.keys
            .filter { $0 < nextPlaybackSegmentIndex }
            .sorted()
        guard staleKeys.isEmpty == false else { return }

        for key in staleKeys {
            if let wav = pendingGenerated.removeValue(forKey: key) {
                cleanupWAV(wav, reason: "stalePending.\(reason)")
            }
        }

        print("""
        [TuringWAVQueue] stale pending wavs removed
          segmentIndexes: \(staleKeys.map(String.init).joined(separator: ","))
          nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
          reason: \(reason)
        """)
    }

    private func cleanupRunDirectory() {
        guard let runDirectory else { return }
        let runRoot = runDirectory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: runRoot.path) {
            try? FileManager.default.removeItem(at: runRoot)
        }
    }
}
