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
    private let engine = AVAudioEngine()
    private let realSpeechNode = AVAudioPlayerNode()
    private let fillerNode = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?

    private var fillerFiles: [URL] = []
    private var lastFillerFile: URL?
    private var fillerGeneration = 0
    private var fillerFadeTask: Task<Void, Never>?
    private var longStallWarningTask: Task<Void, Never>?

    private var runID: String?
    private var expectedSegmentCount: Int?
    private var runActive = false
    private var allComputeFinished = false
    private var activeComputeSegmentIndex: Int?
    private var realSpeechPlayingSegmentIndex: Int?
    private var pendingGeneratedSegments: [Int: TuringComputeGapGeneratedAudio] = [:]
    private var nextPlaybackSegmentIndex = 0
    private var playbackFinishedContinuation: CheckedContinuation<Void, Never>?

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        try configureAudioSessionIfAvailable()
        try configureEngine()
        self.fillerFiles = Self.discoverFillerFiles(
            candidates: configuration.fillerDirectoryCandidates,
            allowedExtensions: configuration.fillerExtensions
        )
        print("""
        [TuringGapAudio] initialized
          fillerClipCount: \(fillerFiles.count)
          playbackSampleRate: \(playbackFormat?.sampleRate ?? 0)
          playbackChannelCount: \(playbackFormat?.channelCount ?? 0)
        """)
    }

    public static func makeBigMikeCoordinator() throws -> TuringComputeGapAudioCoordinator {
        try TuringComputeGapAudioCoordinator()
    }

    public func beginRun(
        runID: String,
        expectedSegmentCount: Int
    ) async {
        self.runID = runID
        self.expectedSegmentCount = expectedSegmentCount
        self.runActive = true
        self.allComputeFinished = false
        self.activeComputeSegmentIndex = nil
        self.realSpeechPlayingSegmentIndex = nil
        self.pendingGeneratedSegments.removeAll(keepingCapacity: true)
        self.nextPlaybackSegmentIndex = 0
        self.fillerGeneration &+= 1
        realSpeechNode.stop()
        fillerNode.stop()
        realSpeechNode.reset()
        fillerNode.reset()
        startEngineIfNeeded()
        print("""
        [TuringGapAudio] run started
          runID: \(runID)
          expectedSegmentCount: \(expectedSegmentCount)
          fillerClipCount: \(fillerFiles.count)
        """)
        await reconcile(reason: "runStarted")
    }

    public func qwenComputeStarted(segmentIndex: Int) async {
        guard runActive else { return }
        activeComputeSegmentIndex = segmentIndex
        print("""
        [TuringGapAudio] qwen compute started
          segmentIndex: \(segmentIndex)
        """)
        await reconcile(reason: "computeStarted")
    }

    public func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async {
        guard runActive else { return }
        if activeComputeSegmentIndex == segmentIndex {
            activeComputeSegmentIndex = nil
        }
        pendingGeneratedSegments[segmentIndex] = audio
        print("""
        [TuringGapAudio] qwen compute finished
          segmentIndex: \(segmentIndex)
          sampleCount: \(audio.samples.count)
          sampleRate: \(audio.sampleRate)
        """)
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
        activeComputeSegmentIndex = nil
        allComputeFinished = true
        pendingGeneratedSegments.removeAll(keepingCapacity: false)
        realSpeechPlayingSegmentIndex = nil
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
            activeComputeSegmentIndex == nil &&
            realSpeechPlayingSegmentIndex == nil &&
            pendingGeneratedSegments.isEmpty
        )
    }

    private func reconcile(reason: String) async {
        guard runActive else { return }

        if realSpeechPlayingSegmentIndex != nil {
            await stopFiller(reason: "realSpeechPlaying", fade: true)
            return
        }

        if let audio = pendingGeneratedSegments.removeValue(forKey: nextPlaybackSegmentIndex) {
            await startRealSpeech(audio, reason: reason)
            return
        }

        if let activeComputeSegmentIndex {
            startFillerIfNeeded(
                reason: "computeWithoutSpeech",
                waitingForSegmentIndex: activeComputeSegmentIndex
            )
            return
        }

        if allComputeFinished && pendingGeneratedSegments.isEmpty {
            await stopFiller(reason: "runFinished", fade: true)
            runActive = false
            print("""
            [TuringGapAudio] run finished
              runID: \(runID ?? "nil")
            """)
            finishWaiterIfNeeded()
        }
    }

    private func startRealSpeech(
        _ audio: TuringComputeGapGeneratedAudio,
        reason: String
    ) async {
        guard runActive else { return }
        await stopFiller(reason: "realSpeechReady", fade: true)

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
                    await self?.realSpeechDidFinish(segmentIndex: audio.segmentIndex)
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

    private func realSpeechDidFinish(segmentIndex: Int) async {
        guard runActive else { return }
        guard realSpeechPlayingSegmentIndex == segmentIndex else { return }
        realSpeechPlayingSegmentIndex = nil
        nextPlaybackSegmentIndex = max(nextPlaybackSegmentIndex, segmentIndex + 1)
        print("""
        [TuringGapAudio] real speech finished
          segmentIndex: \(segmentIndex)
        """)
        await reconcile(reason: "realSpeechFinished")
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

        if fillerNode.isPlaying {
            return
        }

        fillerFadeTask?.cancel()
        fillerGeneration &+= 1
        let generation = fillerGeneration
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

    private func scheduleNextFillerClip(
        generation: Int,
        firstInChain: Bool
    ) {
        guard runActive else { return }
        guard generation == fillerGeneration else { return }
        guard realSpeechPlayingSegmentIndex == nil else { return }
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
                    self?.fillerClipDidFinish(generation: generation)
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
            if fillerFiles.isEmpty == false {
                scheduleNextFillerClip(generation: generation, firstInChain: false)
            }
        }
    }

    private func fillerClipDidFinish(generation: Int) {
        guard runActive else { return }
        guard generation == fillerGeneration else { return }
        guard realSpeechPlayingSegmentIndex == nil else { return }
        guard activeComputeSegmentIndex != nil else { return }
        scheduleNextFillerClip(generation: generation, firstInChain: false)
    }

    private func stopFiller(reason: String, fade: Bool) async {
        longStallWarningTask?.cancel()
        longStallWarningTask = nil

        guard fillerNode.isPlaying else {
            fillerGeneration &+= 1
            fillerNode.stop()
            fillerNode.reset()
            return
        }

        print("""
        [TuringGapAudio] filler stopping
          reason: \(reason)
        """)

        fillerGeneration &+= 1
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
                      self.activeComputeSegmentIndex == waitingForSegmentIndex else { return }
                print("""
                [TuringGapAudio] long compute gap still bridged by filler
                  waitingForSegmentIndex: \(waitingForSegmentIndex)
                  seconds: \(seconds)
                """)
            }
        }
    }

    private func randomFillerURL() -> URL {
        guard fillerFiles.count > 1,
              let lastFillerFile else {
            return fillerFiles.randomElement() ?? fillerFiles[0]
        }
        let candidates = fillerFiles.filter { $0 != lastFillerFile }
        return candidates.randomElement() ?? fillerFiles[0]
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

        urls = Array(Set(urls)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        urls = urls.filter { fileManager.fileExists(atPath: $0.path) }
        return urls
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
