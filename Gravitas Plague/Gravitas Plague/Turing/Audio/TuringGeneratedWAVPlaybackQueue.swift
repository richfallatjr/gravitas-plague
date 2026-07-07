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

    private let writer: TuringGeneratedWAVWriter
    private let fillerLane = TuringBigMikeFillerPlaybackLane()
    private let policy = Policy()

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

    private var activeGeneratedPlayer: AVAudioPlayer?
    private var activeGeneratedSegmentIndex: Int?
    private var activeGeneratedFileURL: URL?
    private var activeGeneratedWAV: TuringGeneratedWAVSegment?

    init(rootURL: URL) {
        self.writer = TuringGeneratedWAVWriter(rootURL: rootURL)
        super.init()
        fillerLane.onFillerFinished = { [weak self] in
            Task { @MainActor in
                await self?.reconcile(reason: "fillerFinished")
            }
        }
    }

    static func makeDefaultQueue() -> TuringGeneratedWAVPlaybackQueue {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TuringGeneratedWAVQueue", isDirectory: true)
        return TuringGeneratedWAVPlaybackQueue(rootURL: root)
    }

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async {
        await cancel(reason: "beginNewRun")
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

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.allComputeFinished = false
        self.nextPlaybackSegmentIndex = 0
        self.firstSegmentPrerollRemaining = policy.firstSegmentPrerollFillerCount
        self.interSegmentFillerRemaining = 0
        self.runActive = true
        self.activeGeneratedPlayer = nil
        self.activeGeneratedSegmentIndex = nil
        self.activeGeneratedFileURL = nil
        self.activeGeneratedWAV = nil

        print("""
        [TuringWAVQueue] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          generatedSpeechFileBacked: true
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          minimumFillerClipsBetweenSegments: \(policy.minimumFillerClipsBetweenSegments)
        """)

        await reconcile(reason: "runStarted")
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
            """)

            if fillerLane.isPlaying,
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
                activeGeneratedPlayer != nil else { return }
        runActive = false
        activeGeneratedPlayer?.stop()
        activeGeneratedPlayer = nil
        activeGeneratedSegmentIndex = nil
        activeGeneratedFileURL = nil
        activeGeneratedWAV = nil
        fillerLane.stopFiller(reason: "queueCancelled.\(reason)")
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
        guard activeGeneratedPlayer == nil else { return }
        guard fillerLane.isPlaying == false else { return }

        while skippedSegments.remove(nextPlaybackSegmentIndex) != nil {
            print("""
            [TuringWAVQueue] skipped segment advanced playback cursor
              segmentIndex: \(nextPlaybackSegmentIndex)
            """)
            nextPlaybackSegmentIndex += 1
            interSegmentFillerRemaining = policy.minimumFillerClipsBetweenSegments
        }

        if isFinished {
            await finishRun(reason: reason)
            return
        }

        if pendingGenerated[nextPlaybackSegmentIndex] != nil,
           firstSegmentPrerollRemaining > 0 {
            firstSegmentPrerollRemaining -= 1
            startFiller(reason: "firstSegmentPreroll", debt: .firstPreroll)
            return
        }

        if pendingGenerated[nextPlaybackSegmentIndex] != nil,
           interSegmentFillerRemaining > 0 {
            interSegmentFillerRemaining -= 1
            startFiller(reason: "interSegmentRequired", debt: .interSegment)
            return
        }

        if let wav = pendingGenerated.removeValue(
            forKey: nextPlaybackSegmentIndex
        ) {
            startGenerated(wav: wav, reason: reason)
            return
        }

        if policy.chainFillerWhileComputeWithoutSpeech,
           nextPlaybackSegmentIndex > 0,
           allComputeFinished == false || activeComputeSegments.isEmpty == false {
            startFiller(reason: "computeWithoutSpeech", debt: .computeGap)
            return
        }
    }

    private func startGenerated(
        wav: TuringGeneratedWAVSegment,
        reason: String
    ) {
        do {
            let player = try AVAudioPlayer(contentsOf: wav.fileURL)
            player.delegate = self
            player.prepareToPlay()
            activeGeneratedPlayer = player
            activeGeneratedSegmentIndex = wav.segmentIndex
            activeGeneratedFileURL = wav.fileURL
            activeGeneratedWAV = wav

            print("""
            [TuringWAVQueue] playback started
              segmentIndex: \(wav.segmentIndex)
              reason: \(reason)
              file: \(wav.fileURL.lastPathComponent)
              durationSeconds: \(String(format: "%.3f", wav.durationSeconds))
            """)

            if player.play() == false {
                activeGeneratedPlayer = nil
                activeGeneratedSegmentIndex = nil
                activeGeneratedFileURL = nil
                activeGeneratedWAV = nil
                cleanupWAV(wav, reason: "playReturnedFalse")
                Task { @MainActor [weak self] in
                    await self?.failRun(
                        reason: "generatedPlaybackStartReturnedFalse.segment\(wav.segmentIndex)"
                    )
                }
            }
        } catch {
            print("""
            [TuringWAVQueue] playback failed
              segmentIndex: \(wav.segmentIndex)
              error: \(error.localizedDescription)
            """)
            cleanupWAV(wav, reason: "playbackStartFailed")
            Task { @MainActor [weak self] in
                await self?.failRun(
                    reason: "generatedPlaybackStartFailed.segment\(wav.segmentIndex)"
                )
            }
        }
    }

    private func startFiller(
        reason: String,
        debt: FillerDebt
    ) {
        do {
            try fillerLane.startFiller(reason: reason)
        } catch {
            print("""
            [TuringWAVQueue] filler start failed
              reason: \(reason)
              debt: \(debt)
              error: \(error.localizedDescription)
            """)
            Task { @MainActor [weak self] in
                await self?.reconcile(reason: "fillerStartFailed")
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            guard player === self.activeGeneratedPlayer else {
                print("""
                [TuringWAVQueue] stale generated player completion ignored
                  successfully: \(flag)
                """)
                return
            }

            let segmentIndex = self.activeGeneratedSegmentIndex
            let wav = self.activeGeneratedWAV
            self.activeGeneratedPlayer = nil
            self.activeGeneratedSegmentIndex = nil
            self.activeGeneratedFileURL = nil
            self.activeGeneratedWAV = nil

            print("""
            [TuringWAVQueue] playback finished
              segmentIndex: \(segmentIndex.map(String.init) ?? "nil")
              successfully: \(flag)
            """)

            if let wav {
                self.cleanupWAV(wav, reason: "playbackFinished")
                self.nextPlaybackSegmentIndex = wav.segmentIndex + 1
            } else if let segmentIndex {
                self.nextPlaybackSegmentIndex = segmentIndex + 1
            }

            self.interSegmentFillerRemaining =
                self.policy.minimumFillerClipsBetweenSegments

            await self.reconcile(reason: "generatedPlaybackFinished")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor in
            guard player === self.activeGeneratedPlayer else { return }
            let segmentIndex = self.activeGeneratedSegmentIndex
            let wav = self.activeGeneratedWAV
            self.activeGeneratedPlayer = nil
            self.activeGeneratedSegmentIndex = nil
            self.activeGeneratedFileURL = nil
            self.activeGeneratedWAV = nil

            print("""
            [TuringWAVQueue] playback decode error
              segmentIndex: \(segmentIndex.map(String.init) ?? "nil")
              error: \(error?.localizedDescription ?? "unknown")
            """)

            if let wav {
                self.cleanupWAV(wav, reason: "decodeError")
            }
            await self.failRun(
                reason: "generatedPlaybackDecodeError.segment\(segmentIndex.map(String.init) ?? "nil")"
            )
        }
    }

    private func finishRun(reason: String) async {
        runActive = false
        fillerLane.stopFiller(reason: "runFinished")
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
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    private func failRun(reason: String) async {
        guard runActive else { return }
        runActive = false
        activeGeneratedPlayer?.stop()
        activeGeneratedPlayer = nil
        activeGeneratedSegmentIndex = nil
        activeGeneratedFileURL = nil
        if let activeGeneratedWAV {
            cleanupWAV(activeGeneratedWAV, reason: "failedRun")
        }
        activeGeneratedWAV = nil
        fillerLane.stopFiller(reason: "runFailed.\(reason)")
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
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    private var isFinished: Bool {
        if activeGeneratedPlayer != nil || fillerLane.isPlaying {
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
        let pending = pendingGenerated.values
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
}
