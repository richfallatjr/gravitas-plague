import AVFoundation
import Foundation

@MainActor
public final class TuringSerialWAVFillerPlaybackQueue: NSObject, AVAudioPlayerDelegate {
    public struct Policy: Sendable {
        public var firstSegmentPrerollFillerCount: Int
        public var minimumFillerClipsBetweenSegments: Int
        public var chainFillerWhileComputeWithoutSpeech: Bool
        public var completeCurrentFillerBeforeGeneratedSpeech: Bool
        public var deadAirAfterFillerEnabled: Bool
        public var deadAirMinSeconds: Double
        public var deadAirMaxSeconds: Double
        public var avoidImmediateFillerRepeat: Bool
        public var fillerDirectoryCandidates: [String]
        public var fillerExtensions: Set<String>

        public static let bigMikeDefault = Policy(
            firstSegmentPrerollFillerCount: 1,
            minimumFillerClipsBetweenSegments: 1,
            chainFillerWhileComputeWithoutSpeech: true,
            completeCurrentFillerBeforeGeneratedSpeech: true,
            deadAirAfterFillerEnabled: true,
            deadAirMinSeconds: 0.5,
            deadAirMaxSeconds: 4.0,
            avoidImmediateFillerRepeat: true,
            fillerDirectoryCandidates: [
                "Turing/Audio/big-mike-filler",
                "Turing/big-mike-filler",
                "big-mike-filler"
            ],
            fillerExtensions: ["wav", "mp3", "m4a", "aiff", "caf"]
        )
    }

    private enum ActiveItem: Equatable {
        case none
        case generated(segmentIndex: Int, url: URL)
        case filler(url: URL)
        case deadAir
        case cancelled
    }

    private let rootURL: URL
    private let policy: Policy
    private var runDirectory: URL?
    private var runID: String?
    private var expectedSegmentCount: Int?
    private var runActive = false
    private var allComputeFinished = false

    private var nextPlaybackSegmentIndex = 0
    private var activeComputeSegments = Set<Int>()
    private var pendingGenerated: [Int: TuringGeneratedWAVSegment] = [:]
    private var skippedSegments = Set<Int>()

    private var activeItem: ActiveItem = .none
    private var activePlayer: AVAudioPlayer?
    private var deadAirTask: Task<Void, Never>?
    private var waitContinuations: [CheckedContinuation<Void, Never>] = []

    private var fillerFiles: [URL]
    private var fillerQueue: [URL] = []
    private var lastFillerFile: URL?
    private var firstPrerollRemaining: Int
    private var interSegmentFillerRemaining = 0

    public init(
        rootURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TuringSerialWAVFillerQueue", isDirectory: true),
        policy: Policy = .bigMikeDefault
    ) {
        self.rootURL = rootURL
        self.policy = policy
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: policy.fillerDirectoryCandidates,
            allowedExtensions: policy.fillerExtensions
        )
        self.firstPrerollRemaining = policy.firstSegmentPrerollFillerCount
        super.init()
    }

    public static func makeBigMikeQueue() -> TuringSerialWAVFillerPlaybackQueue {
        TuringSerialWAVFillerPlaybackQueue()
    }

    public func beginRun(runID: String, expectedSegmentCount: Int?) async {
        await cancel(reason: "beginNewRun", endingPlaybackOwner: false)

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.runActive = true
        self.allComputeFinished = false
        self.nextPlaybackSegmentIndex = 0
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.pendingGenerated.removeAll(keepingCapacity: true)
        self.skippedSegments.removeAll(keepingCapacity: true)
        self.activeItem = .none
        self.firstPrerollRemaining = policy.firstSegmentPrerollFillerCount
        self.interSegmentFillerRemaining = 0

        let safeRunID = runID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let directory = rootURL.appendingPathComponent(safeRunID, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runDirectory = directory

        TuringAudioSessionCoordinator.shared.beginPlayback(owner: "TuringSerialWAVFillerPlaybackQueue")

        print("""
        [TuringSerialQueue] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          fillerClipCount: \(fillerFiles.count)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
          minimumFillerClipsBetweenSegments: \(policy.minimumFillerClipsBetweenSegments)
          playbackTruth: AVAudioPlayerDelegate
        """)

        await reconcile(reason: "runStarted")
    }

    public func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        activeComputeSegments.insert(segmentIndex)
        print("""
        [TuringSerialQueue] qwen compute started
          segmentIndex: \(segmentIndex)
          activeItem: \(activeItemLog)
        """)
        await reconcile(reason: "computeStarted")
    }

    public func qwenComputeFinished(segmentIndex: Int, audio: TuringComputeGapGeneratedAudio) async {
        guard runActive else { return }
        activeComputeSegments.remove(segmentIndex)

        do {
            let wav = try writeGeneratedWAV(audio: audio, segmentIndex: segmentIndex)
            pendingGenerated[segmentIndex] = wav
            print("""
            [TuringSerialQueue] generated queued
              segmentIndex: \(segmentIndex)
              durationSeconds: \(String(format: "%.3f", wav.durationSeconds))
              pending: \(pendingIndexesLog)
              computeContinues: true
            """)
        } catch {
            print("""
            [TuringSerialQueue] fatal wav write failed
              segmentIndex: \(segmentIndex)
              error: \(error.localizedDescription)
            """)
            await cancel(reason: "wavWriteFailed.segment\(segmentIndex)")
            return
        }

        await reconcile(reason: "computeFinished")
    }

    public func qwenComputeSkipped(segmentIndex: Int, reason: String) async {
        guard runActive else { return }
        activeComputeSegments.remove(segmentIndex)
        skippedSegments.insert(segmentIndex)
        print("""
        [TuringSerialQueue] compute skipped
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
        await reconcile(reason: "computeSkipped")
    }

    public func qwenComputeAllFinished() async {
        guard runActive else { return }
        allComputeFinished = true
        print("[TuringSerialQueue] qwen compute all finished")
        await reconcile(reason: "computeAllFinished")
    }

    public func waitUntilPlaybackFinished() async {
        if isFinished {
            return
        }
        await withCheckedContinuation { continuation in
            waitContinuations.append(continuation)
        }
    }

    public func cancel(reason: String) async {
        await cancel(reason: reason, endingPlaybackOwner: true)
    }

    private func cancel(reason: String, endingPlaybackOwner: Bool) async {
        guard runActive || activePlayer != nil || deadAirTask != nil else { return }
        runActive = false
        activeItem = .cancelled
        deadAirTask?.cancel()
        deadAirTask = nil
        activePlayer?.stop()
        activePlayer?.delegate = nil
        activePlayer = nil
        cleanupAllWAVs(reason: "cancel.\(reason)")
        pendingGenerated.removeAll(keepingCapacity: false)
        skippedSegments.removeAll(keepingCapacity: false)
        activeComputeSegments.removeAll(keepingCapacity: false)
        if endingPlaybackOwner {
            TuringAudioSessionCoordinator.shared.endPlayback(owner: "TuringSerialWAVFillerPlaybackQueue")
        }
        print("""
        [TuringSerialQueue] run cancelled
          reason: \(reason)
        """)
        resumeWaiters()
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }
        guard activeItem == .none else { return }

        while skippedSegments.remove(nextPlaybackSegmentIndex) != nil {
            nextPlaybackSegmentIndex += 1
        }

        if nextPlaybackSegmentIndex == 0,
           firstPrerollRemaining > 0,
           pendingGenerated[0] != nil {
            firstPrerollRemaining -= 1
            await startFiller(reason: "firstSegmentPreroll")
            return
        }

        if nextPlaybackSegmentIndex > 0,
           interSegmentFillerRemaining > 0,
           pendingGenerated[nextPlaybackSegmentIndex] != nil {
            interSegmentFillerRemaining -= 1
            await startFiller(reason: "interSegmentBuffer")
            return
        }

        if let wav = pendingGenerated.removeValue(forKey: nextPlaybackSegmentIndex) {
            await startGenerated(wav, reason: reason)
            return
        }

        if policy.chainFillerWhileComputeWithoutSpeech,
           activeComputeSegments.isEmpty == false {
            await startFiller(reason: "computeWithoutSpeech")
            return
        }

        if allComputeFinished,
           activeComputeSegments.isEmpty,
           pendingGenerated.isEmpty,
           skippedSegments.isEmpty,
           activeItem == .none {
            await finishRun(reason: "allDone")
        }
    }

    private func startGenerated(_ wav: TuringGeneratedWAVSegment, reason: String) async {
        guard activeItem == .none else {
            pendingGenerated[wav.segmentIndex] = wav
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: wav.fileURL)
            player.delegate = self
            player.prepareToPlay()
            activePlayer = player
            activeItem = .generated(segmentIndex: wav.segmentIndex, url: wav.fileURL)
            let didStart = player.play()
            guard didStart else {
                throw NSError(domain: "TuringSerialQueue", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play returned false"])
            }
            print("""
            [TuringSerialQueue] generated playback started
              segmentIndex: \(wav.segmentIndex)
              reason: \(reason)
              file: \(wav.fileURL.lastPathComponent)
              durationSeconds: \(String(format: "%.3f", wav.durationSeconds))
            """)
        } catch {
            cleanupWAV(wav.fileURL, reason: "generatedStartFailed")
            print("""
            [TuringSerialQueue] generated playback failed
              segmentIndex: \(wav.segmentIndex)
              error: \(error.localizedDescription)
            """)
            skippedSegments.insert(wav.segmentIndex)
            activeItem = .none
            activePlayer = nil
            await reconcile(reason: "generatedStartFailed")
        }
    }

    private func startFiller(reason: String) async {
        guard activeItem == .none else { return }
        guard let fileURL = nextFillerURL() else {
            if pendingGenerated[nextPlaybackSegmentIndex] == nil,
               policy.deadAirAfterFillerEnabled {
                startDeadAir(reason: "noFillerFiles")
            }
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            activePlayer = player
            activeItem = .filler(url: fileURL)
            lastFillerFile = fileURL
            let didStart = player.play()
            guard didStart else {
                throw NSError(domain: "TuringSerialQueue", code: 2, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play returned false"])
            }
            print("""
            [TuringSerialQueue] filler playback started
              reason: \(reason)
              clip: \(fileURL.lastPathComponent)
              playbackTruth: AVAudioPlayerDelegate
            """)
        } catch {
            print("""
            [TuringSerialQueue] filler playback failed
              clip: \(fileURL.lastPathComponent)
              error: \(error.localizedDescription)
            """)
            activePlayer = nil
            activeItem = .none
            await reconcile(reason: "fillerStartFailed")
        }
    }

    private func startDeadAir(reason: String) {
        guard activeItem == .none else { return }
        let minSeconds = min(policy.deadAirMinSeconds, policy.deadAirMaxSeconds)
        let maxSeconds = max(policy.deadAirMinSeconds, policy.deadAirMaxSeconds)
        let seconds = Double.random(in: minSeconds...maxSeconds)
        activeItem = .deadAir
        print("""
        [TuringSerialQueue] dead air started
          reason: \(reason)
          seconds: \(String(format: "%.2f", seconds))
        """)
        deadAirTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                Task { @MainActor in
                    await self?.deadAirFinished()
                }
            }
        }
    }

    private func deadAirFinished() async {
        guard activeItem == .deadAir else { return }
        activeItem = .none
        deadAirTask = nil
        print("[TuringSerialQueue] dead air finished")
        await reconcile(reason: "deadAirFinished")
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            await self.activePlayerCompleted(player: player, successfully: flag)
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            await self.activePlayerCompleted(player: player, successfully: false)
        }
    }

    private func activePlayerCompleted(player: AVAudioPlayer, successfully: Bool) async {
        guard activePlayer === player else {
            print("""
            [TuringSerialQueue] stale playback completion ignored
              item: \(activeItemLog)
              successfully: \(successfully)
              reason: playerIdentityMismatch
            """)
            return
        }

        let completedItem = activeItem
        activePlayer?.delegate = nil
        activePlayer = nil
        activeItem = .none

        switch completedItem {
        case .generated(let segmentIndex, let url):
            cleanupWAV(url, reason: "generatedPlaybackFinished")
            nextPlaybackSegmentIndex = segmentIndex + 1
            if shouldRequireInterSegmentFiller(after: segmentIndex) {
                interSegmentFillerRemaining = max(interSegmentFillerRemaining, policy.minimumFillerClipsBetweenSegments)
            }
            print("""
            [TuringSerialQueue] generated playback finished
              segmentIndex: \(segmentIndex)
              successfully: \(successfully)
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)

        case .filler(let url):
            print("""
            [TuringSerialQueue] filler playback finished
              clip: \(url.lastPathComponent)
              successfully: \(successfully)
              pendingNextReady: \(pendingGenerated[nextPlaybackSegmentIndex] != nil)
            """)
            if pendingGenerated[nextPlaybackSegmentIndex] == nil,
               policy.deadAirAfterFillerEnabled,
               activeComputeSegments.isEmpty == false {
                startDeadAir(reason: "afterFiller")
                return
            }

        case .none, .deadAir, .cancelled:
            print("""
            [TuringSerialQueue] stale playback completion ignored
              item: \(activeItemLog)
              successfully: \(successfully)
            """)
        }

        await reconcile(reason: "playerCompleted")
    }

    private func shouldRequireInterSegmentFiller(after segmentIndex: Int) -> Bool {
        guard policy.minimumFillerClipsBetweenSegments > 0 else { return false }
        if let expectedSegmentCount {
            return segmentIndex + 1 < expectedSegmentCount
        }
        return allComputeFinished == false ||
            activeComputeSegments.isEmpty == false ||
            pendingGenerated[segmentIndex + 1] != nil
    }

    private func finishRun(reason: String) async {
        runActive = false
        activeItem = .none
        cleanupAllWAVs(reason: "finishRun")
        TuringAudioSessionCoordinator.shared.endPlayback(owner: "TuringSerialWAVFillerPlaybackQueue")
        print("""
        [TuringSerialQueue] run finished
          reason: \(reason)
          runID: \(runID ?? "nil")
        """)
        resumeWaiters()
    }

    private var isFinished: Bool {
        runActive == false && activePlayer == nil && activeItem != .deadAir
    }

    private func resumeWaiters() {
        let continuations = waitContinuations
        waitContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func writeGeneratedWAV(audio: TuringComputeGapGeneratedAudio, segmentIndex: Int) throws -> TuringGeneratedWAVSegment {
        guard let runDirectory else {
            throw NSError(domain: "TuringSerialQueue", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing run directory"])
        }
        guard audio.samples.isEmpty == false else {
            throw NSError(domain: "TuringSerialQueue", code: 11, userInfo: [NSLocalizedDescriptionKey: "Empty generated samples"])
        }
        let finalURL = runDirectory.appendingPathComponent(String(format: "segment_%04d.wav", segmentIndex))
        let tmpURL = runDirectory.appendingPathComponent(String(format: "segment_%04d.tmp.wav", segmentIndex))
        try? FileManager.default.removeItem(at: tmpURL)
        try? FileManager.default.removeItem(at: finalURL)

        let channelCount = max(1, Int(audio.channelCount))
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
                frameCapacity: AVAudioFrameCount(audio.samples.count / channelCount)
            ) else {
                throw NSError(domain: "TuringSerialQueue", code: 12, userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffer"])
            }
            let frameCount = audio.samples.count / channelCount
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channels = buffer.floatChannelData else {
                throw NSError(domain: "TuringSerialQueue", code: 13, userInfo: [NSLocalizedDescriptionKey: "Missing floatChannelData"])
            }
            if channelCount == 1 {
                let channel = channels[0]
                for i in 0..<frameCount {
                    let value = audio.samples[i]
                    channel[i] = value.isFinite ? max(-1, min(1, value)) : 0
                }
            } else {
                for c in 0..<channelCount {
                    let channel = channels[c]
                    for i in 0..<frameCount {
                        let value = audio.samples[i * channelCount + c]
                        channel[i] = value.isFinite ? max(-1, min(1, value)) : 0
                    }
                }
            }
            try file.write(from: buffer)
        }

        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        let validation = try AVAudioFile(forReading: finalURL)
        let sampleRate = validation.fileFormat.sampleRate
        let duration = sampleRate > 0 ? Double(validation.length) / sampleRate : 0
        guard validation.length > 0, duration > 0 else {
            throw NSError(domain: "TuringSerialQueue", code: 14, userInfo: [NSLocalizedDescriptionKey: "WAV validation produced zero duration"])
        }
        print("""
        [TuringSerialQueue] wav written
          segmentIndex: \(segmentIndex)
          file: \(finalURL.lastPathComponent)
          frameCount: \(validation.length)
          sampleRate: \(sampleRate)
          durationSeconds: \(String(format: "%.3f", duration))
        """)
        return TuringGeneratedWAVSegment(
            segmentIndex: segmentIndex,
            fileURL: finalURL,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: validation.length,
            durationSeconds: duration
        )
    }

    private func cleanupWAV(_ url: URL, reason: String) {
        try? FileManager.default.removeItem(at: url)
        print("""
        [TuringSerialQueue] wav cleaned
          file: \(url.lastPathComponent)
          reason: \(reason)
        """)
    }

    private func cleanupAllWAVs(reason: String) {
        for wav in pendingGenerated.values {
            cleanupWAV(wav.fileURL, reason: reason)
        }
        pendingGenerated.removeAll()
        if let runDirectory {
            try? FileManager.default.removeItem(at: runDirectory)
        }
        runDirectory = nil
    }

    private func nextFillerURL() -> URL? {
        if fillerQueue.isEmpty {
            fillerQueue = fillerFiles.shuffled()
        }
        if policy.avoidImmediateFillerRepeat,
           let lastFillerFile,
           fillerQueue.count > 1,
           fillerQueue.first == lastFillerFile,
           let replacementIndex = fillerQueue.firstIndex(where: { $0 != lastFillerFile }) {
            fillerQueue.swapAt(0, replacementIndex)
        }
        guard fillerQueue.isEmpty == false else { return nil }
        return fillerQueue.removeFirst()
    }

    private var activeItemLog: String {
        switch activeItem {
        case .none: return "none"
        case .generated(let segmentIndex, _): return "generated.\(segmentIndex)"
        case .filler(let url): return "filler.\(url.lastPathComponent)"
        case .deadAir: return "deadAir"
        case .cancelled: return "cancelled"
        }
    }

    private var pendingIndexesLog: String {
        let indexes = pendingGenerated.keys.sorted()
        return indexes.isEmpty ? "none" : indexes.map(String.init).joined(separator: ",")
    }

    private static func discoverFillerFiles(candidates: [String], allowedExtensions: Set<String>) -> [URL] {
        var urls: [URL] = []
        let bundle = Bundle.main
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
        return Array(Set(urls)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func filesUnder(_ root: URL, allowedExtensions: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if allowedExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }
}
