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

@MainActor
final class TuringStoryWalkiePlaybackCoordinator {
    struct Policy: Sendable {
        var firstSegmentPrerollFillerCount = 1
        var chainFillerWhileComputeWithoutSpeech = true
        var completeCurrentFillerBeforeGeneratedSpeech = true
        var deadAirAfterFillerEnabled = true
        var deadAirMinSeconds = 0.5
        var deadAirMaxSeconds = 4.0
        var avoidImmediateFillerRepeat = true
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
        let durationSeconds: Double
    }

    private enum ActiveItem: Equatable {
        case none
        case generated(segmentIndex: Int, handleID: UUID, fileURL: URL)
        case filler(handleID: UUID, fileURL: URL)
        case deadAir(id: UUID)
        case cancelled
    }

    private let policy: Policy
    private let rootURL: URL
    private var runDirectory: URL?
    private var runActive = false
    private var runID: String?
    private var expectedSegmentCount: Int?
    private var nextPlaybackSegmentIndex = 0
    private var activeComputeSegments = Set<Int>()
    private var pendingGenerated: [Int: GeneratedClip] = [:]
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
            .appendingPathComponent("TuringStoryWalkiePlayback", isDirectory: true)
    ) {
        self.policy = policy
        self.rootURL = rootURL
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: policy.fillerDirectoryCandidates,
            allowedExtensions: policy.fillerExtensions
        )
    }

    static func makeBigMikeCoordinator() -> TuringStoryWalkiePlaybackCoordinator {
        TuringStoryWalkiePlaybackCoordinator()
    }

    func beginRun(runID: String, expectedSegmentCount: Int?) async {
        await runCancelled(reason: "beginNewRun", endPlaybackOwner: false)

        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.nextPlaybackSegmentIndex = 0
        self.activeComputeSegments.removeAll(keepingCapacity: true)
        self.pendingGenerated.removeAll(keepingCapacity: true)
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

        TuringAudioSessionCoordinator.shared.beginPlayback(
            owner: "TuringStoryWalkiePlaybackCoordinator"
        )

        print("""
        [TuringPlaybackRebuild] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount.map(String.init) ?? "streaming")
          playbackOwner: TuringStoryWalkiePlaybackCoordinator
          spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
          qwenScheduler: fresh2
          fillerClipCount: \(Set(fillerFiles).count)
          weightedFillerEntryCount: \(fillerFiles.count)
          firstSegmentPrerollFillerCount: \(policy.firstSegmentPrerollFillerCount)
        """)

        await reconcile(reason: "runStarted")
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
            let clip = try writeGeneratedWAV(audio: audio, segmentIndex: segmentIndex)
            pendingGenerated[segmentIndex] = clip
            print("""
            [TuringPlaybackRebuild] generated wav written
              segmentIndex: \(segmentIndex)
              file: \(clip.fileURL.lastPathComponent)
              frameCount: \(clip.frameCount)
              sampleRate: \(clip.sampleRate)
              durationSeconds: \(String(format: "%.3f", clip.durationSeconds))
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

    func runCancelled(reason: String) async {
        await runCancelled(reason: reason, endPlaybackOwner: true)
    }

    private func runCancelled(reason: String, endPlaybackOwner: Bool) async {
        guard runActive || activeItem != .none else { return }
        runActive = false
        activeItem = .cancelled
        deadAirTask?.cancel()
        deadAirTask = nil
        TuringStoryWalkieAudioRoute.makeActiveClipPlayer()?
            .cancelAll(reason: reason)
        cleanupAllWAVs(reason: "cancel.\(reason)")
        pendingGenerated.removeAll(keepingCapacity: false)
        skippedSegments.removeAll(keepingCapacity: false)
        activeComputeSegments.removeAll(keepingCapacity: false)
        if endPlaybackOwner {
            TuringAudioSessionCoordinator.shared.endPlayback(
                owner: "TuringStoryWalkiePlaybackCoordinator"
            )
        }
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

        if firstPrerollRemaining > 0,
           (pendingGenerated[nextPlaybackSegmentIndex] != nil ||
            activeComputeSegments.isEmpty == false) {
            firstPrerollRemaining -= 1
            await startFiller(reason: "firstSegmentPreroll")
            return
        }

        if let clip = pendingGenerated.removeValue(forKey: nextPlaybackSegmentIndex) {
            await startGenerated(clip, reason: reason)
            return
        }

        if activeComputeSegments.isEmpty == false,
           policy.chainFillerWhileComputeWithoutSpeech {
            await startFiller(reason: "computeWithoutSpeech")
            return
        }

        if isFinished {
            await finishRun(reason: "allDone")
        }
    }

    private func startGenerated(_ clip: GeneratedClip, reason: String) async {
        guard activeItem == .none else {
            pendingGenerated[clip.segmentIndex] = clip
            return
        }
        guard let clipPlayer = TuringStoryWalkieAudioRoute.makeActiveClipPlayer() else {
            cleanupWAV(clip.fileURL, reason: "missingWalkieClipPlayer")
            print("""
            [TuringPlaybackRebuild] generated playback blocked
              segmentIndex: \(clip.segmentIndex)
              reason: missingWalkieClipPlayer
              requiredEmitter: TuringStoryWalkieTalkie_AudioEmitter
            """)
            await runCancelled(reason: "missingWalkieClipPlayer.generated.\(clip.segmentIndex)")
            return
        }

        do {
            let handleID = try clipPlayer.playOneShot(
                fileURL: clip.fileURL,
                kind: .generated,
                label: String(format: "segment_%04d", clip.segmentIndex),
                completion: { [weak self] handleID in
                    Task { @MainActor in
                        await self?.playbackCompleted(handleID: handleID)
                    }
                }
            )
            activeItem = .generated(
                segmentIndex: clip.segmentIndex,
                handleID: handleID,
                fileURL: clip.fileURL
            )
            print("""
            [TuringPlaybackRebuild] generated playback started
              segmentIndex: \(clip.segmentIndex)
              handleID: \(handleID.uuidString)
              reason: \(reason)
              file: \(clip.fileURL.lastPathComponent)
              spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
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
        guard let clipPlayer = TuringStoryWalkieAudioRoute.makeActiveClipPlayer() else {
            print("""
            [TuringPlaybackRebuild] filler blocked
              reason: missingWalkieClipPlayer
              requiredEmitter: TuringStoryWalkieTalkie_AudioEmitter
            """)
            await runCancelled(reason: "missingWalkieClipPlayer.filler")
            return
        }

        do {
            let handleID = try clipPlayer.playOneShot(
                fileURL: fillerURL,
                kind: .filler,
                label: fillerURL.deletingPathExtension().lastPathComponent,
                completion: { [weak self] handleID in
                    Task { @MainActor in
                        await self?.playbackCompleted(handleID: handleID)
                    }
                }
            )
            lastFillerURL = fillerURL
            activeItem = .filler(handleID: handleID, fileURL: fillerURL)
            print("""
            [TuringPlaybackRebuild] filler started
              reason: \(reason)
              clip: \(fillerURL.lastPathComponent)
              handleID: \(handleID.uuidString)
              spatialEmitter: TuringStoryWalkieTalkie_AudioEmitter
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

    private func playbackCompleted(handleID: UUID) async {
        switch activeItem {
        case .generated(let segmentIndex, let activeHandleID, let fileURL)
            where activeHandleID == handleID:
            cleanupWAV(fileURL, reason: "generatedPlaybackCompleted")
            nextPlaybackSegmentIndex = segmentIndex + 1
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] generated playback completed
              segmentIndex: \(segmentIndex)
              handleID: \(handleID.uuidString)
              completionSource: actualPlaybackCompletion
              nextPlaybackSegmentIndex: \(nextPlaybackSegmentIndex)
            """)
            await reconcile(reason: "generatedCompleted")

        case .filler(let activeHandleID, let fileURL)
            where activeHandleID == handleID:
            activeItem = .none
            print("""
            [TuringPlaybackRebuild] filler completed
              handleID: \(handleID.uuidString)
              clip: \(fileURL.lastPathComponent)
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

    private func finishRun(reason: String) async {
        guard runActive else { return }
        runActive = false
        TuringAudioSessionCoordinator.shared.endPlayback(
            owner: "TuringStoryWalkiePlaybackCoordinator"
        )
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
        let duration = sampleRate > 0
            ? Double(validation.length) / sampleRate
            : 0
        guard validation.length > 0, duration > 0 else {
            throw NSError(
                domain: "TuringPlaybackRebuild",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Generated WAV validation produced zero duration."]
            )
        }

        return GeneratedClip(
            segmentIndex: segmentIndex,
            fileURL: finalURL,
            frameCount: validation.length,
            sampleRate: sampleRate,
            durationSeconds: duration
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
        case .generated(let segmentIndex, let handleID, _):
            return "generated.\(segmentIndex).\(handleID.uuidString)"
        case .filler(let handleID, let fileURL):
            return "filler.\(fileURL.lastPathComponent).\(handleID.uuidString)"
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
}
