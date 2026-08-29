import AVFoundation
import Foundation

actor TuringGeneratedPlaybackFileStore {
    struct PreparedClip: Sendable, Equatable {
        let runID: String
        let segmentIndex: Int
        let fileURL: URL
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let generatedVisualAnalysis: TuringGeneratedSpeechVisualAnalysis?
        let generatedVisualAnalysisStatus: TuringGeneratedSpeechAnalysisUnavailableReason?
        let generatedVisualAnalysisNanoseconds: UInt64?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.runID == rhs.runID &&
                lhs.segmentIndex == rhs.segmentIndex &&
                lhs.fileURL == rhs.fileURL &&
                lhs.frameCount == rhs.frameCount &&
                lhs.sampleRate == rhs.sampleRate &&
                lhs.channelCount == rhs.channelCount &&
                lhs.generatedVisualAnalysisStatus == rhs.generatedVisualAnalysisStatus &&
                lhs.generatedVisualAnalysisNanoseconds == rhs.generatedVisualAnalysisNanoseconds &&
                Self.trackIdentity(lhs.generatedVisualAnalysis?.frameTrack) ==
                    Self.trackIdentity(rhs.generatedVisualAnalysis?.frameTrack)
        }

        private static func trackIdentity(
            _ track: TuringGeneratedSpeechFrameTrack?
        ) -> [Int]? {
            track.map {
                [$0.sampleRate, $0.sampleCount, $0.frameCount, $0.poseRuns.count]
            }
        }
    }

    private let rootURL: URL
    private let generatedSpeechAnalysisWorker: TuringSerialGeneratedSpeechAnalysisWorker
    private let generatedSpeechAnalysisBudget: TuringGeneratedSpeechAnalysisBudget
    private var directoriesByRunID: [String: URL] = [:]

    init(
        rootURL: URL,
        generatedSpeechAnalysisWorker: TuringSerialGeneratedSpeechAnalysisWorker =
            TuringSerialGeneratedSpeechAnalysisWorker(),
        generatedSpeechAnalysisBudget: TuringGeneratedSpeechAnalysisBudget = .production
    ) {
        self.rootURL = rootURL
        self.generatedSpeechAnalysisWorker = generatedSpeechAnalysisWorker
        self.generatedSpeechAnalysisBudget = generatedSpeechAnalysisBudget
    }

    func beginRun(_ runID: String) throws -> URL {
        TuringAudioOffloadSignposts.assertNotMainThread("beginRun")
        let safe = runID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = rootURL.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        directoriesByRunID[runID] = directory
        return directory
    }

    func write(
        runID: String,
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async throws -> PreparedClip {
        TuringAudioOffloadSignposts.assertNotMainThread("writeGeneratedWAV")
        TuringAudioOffloadSignposts.offMain(
            "writeGeneratedWAV",
            file: String(format: "segment_%04d.wav", segmentIndex)
        )
        guard let directory = directoriesByRunID[runID] else {
            throw TuringRuntimeError.invalidConfig(
                "No generated-audio directory for run \(runID)."
            )
        }
        guard audio.samples.isEmpty == false,
              audio.sampleRate > 0,
              audio.channelCount > 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Generated segment \(segmentIndex) has invalid audio metadata."
            )
        }

        let channelCount = audio.channelCount
        let channelCountInt = Int(channelCount)
        let totalFrames = audio.samples.count / channelCountInt
        guard totalFrames > 0,
              totalFrames * channelCountInt == audio.samples.count else {
            throw TuringRuntimeError.invalidConfig(
                "Generated segment \(segmentIndex) sample count is not divisible by channel count."
            )
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: channelCount,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        ), let channelData = buffer.floatChannelData else {
            throw TuringRuntimeError.invalidConfig(
                "Could not allocate generated-audio buffer."
            )
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        let sampleRate = Int(audio.sampleRate.rounded())
        let analysisTask: Task<TuringGeneratedSpeechAnalysisResult, Never>?
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            let analysisStarted = ContinuousClock.now
            let analysisDeadline = analysisStarted.advanced(
                by: generatedSpeechAnalysisBudget.hardBudget
            )
            let worker = generatedSpeechAnalysisWorker
            analysisTask = Task.detached(priority: .userInitiated) {
                await worker.analyze(
                    processedAudio: audio.samples,
                    sampleRate: sampleRate,
                    channelCount: channelCountInt,
                    deadline: analysisDeadline
                )
            }
            print(
                "[TuringGeneratedSpeech] analysisStart segmentIndex=\(segmentIndex) " +
                    "processedAudioSamples=\(audio.samples.count) sampleRate=\(sampleRate) " +
                    "channelCount=\(channelCountInt)"
            )
        } else {
            analysisTask = nil
            print(
                "[TuringGeneratedSpeech] analysisSkipped segmentIndex=\(segmentIndex) " +
                    "reason=qualificationControlDisabled audioContinues=true"
            )
        }
        defer { analysisTask?.cancel() }
        for frame in 0..<totalFrames {
            for channel in 0..<channelCountInt {
                let value = audio.samples[frame * channelCountInt + channel]
                channelData[channel][frame] = value.isFinite
                    ? max(-1, min(1, value))
                    : 0
            }
        }

        let stem = String(format: "segment_%04d", segmentIndex)
        let temporaryURL = directory.appendingPathComponent("\(stem).tmp.wav")
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: finalURL)

        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

        let validation = try AVAudioFile(forReading: finalURL)
        guard validation.length > 0,
              validation.fileFormat.sampleRate == audio.sampleRate,
              validation.fileFormat.channelCount == channelCount else {
            try? FileManager.default.removeItem(at: finalURL)
            throw TuringRuntimeError.invalidConfig(
                "Generated WAV validation failed for segment \(segmentIndex)."
            )
        }

        #if GR_MIND_EYE_QUALIFICATION
        Task { @MainActor in
            MindEyeReleaseQualificationHooks.shared.fireAndForget(
                .generatedPCMReady,
                playbackRunID: runID,
                mediaIdentity: "generated:\(segmentIndex)"
            )
        }
        #endif

        let fileReady = ContinuousClock.now
        let analysisResult: TuringGeneratedSpeechAnalysisResult
        if let analysisTask {
            analysisResult = await TuringGeneratedSpeechAnalysisRace.resolve(
                task: analysisTask,
                grace: generatedSpeechAnalysisBudget.postFileWriteGrace
            )
        } else {
            analysisResult = .unavailable(reason: .cancelled)
        }
        let addedWaitNanoseconds = Self.nanoseconds(fileReady.duration(to: ContinuousClock.now))
        let visualAnalysis: TuringGeneratedSpeechVisualAnalysis?
        let unavailableReason: TuringGeneratedSpeechAnalysisUnavailableReason?
        let analysisNanoseconds: UInt64?
        switch analysisResult {
        case .ready(let value):
            visualAnalysis = value
            unavailableReason = nil
            analysisNanoseconds = value.envelope.diagnostics.analysisNanoseconds
            print(
                "[TuringGeneratedSpeech] analysisComplete segmentIndex=\(segmentIndex) " +
                    "analysisNanoseconds=\(analysisNanoseconds ?? 0) " +
                    "addedWaitNanoseconds=\(addedWaitNanoseconds) " +
                    "frames=\(value.frameTrack.frameCount) runs=\(value.frameTrack.poseRuns.count)"
            )
            #if GR_MIND_EYE_QUALIFICATION
            Task { @MainActor in
                MindEyeReleaseQualificationHooks.shared.fireAndForget(
                    .generatedAnalysisReady,
                    playbackRunID: runID,
                    mediaIdentity: "generated:\(segmentIndex)",
                    timing: MindEyeReleaseTimingSnapshot(
                        generatedAnalysisMilliseconds: Double(analysisNanoseconds ?? 0) / 1_000_000
                    )
                )
            }
            #endif
        case .unavailable(let reason):
            analysisTask?.cancel()
            visualAnalysis = nil
            unavailableReason = reason
            analysisNanoseconds = nil
            print(
                "[TuringGeneratedSpeech] analysisUnavailable segmentIndex=\(segmentIndex) " +
                    "status=\(reason.rawValue) addedWaitNanoseconds=\(addedWaitNanoseconds) " +
                    "audioContinues=true"
            )
        }
        return PreparedClip(
            runID: runID,
            segmentIndex: segmentIndex,
            fileURL: finalURL,
            frameCount: validation.length,
            sampleRate: validation.fileFormat.sampleRate,
            channelCount: validation.fileFormat.channelCount,
            generatedVisualAnalysis: visualAnalysis,
            generatedVisualAnalysisStatus: unavailableReason,
            generatedVisualAnalysisNanoseconds: analysisNanoseconds
        )
    }

    func delete(_ clip: PreparedClip, reason: String) {
        TuringAudioOffloadSignposts.assertNotMainThread("deleteGeneratedWAV")
        try? FileManager.default.removeItem(at: clip.fileURL)
        print("""
        [TuringAudioOffload] generated file deleted
          runID: \(clip.runID)
          segmentIndex: \(clip.segmentIndex)
          reason: \(reason)
        """)
    }

    func delete(
        fileURL: URL,
        runID: String,
        segmentIndex: Int,
        reason: String
    ) {
        TuringAudioOffloadSignposts.assertNotMainThread("deleteGeneratedWAV")
        try? FileManager.default.removeItem(at: fileURL)
        print("""
        [TuringAudioOffload] generated file deleted
          runID: \(runID)
          segmentIndex: \(segmentIndex)
          reason: \(reason)
        """)
    }

    func endRun(_ runID: String, reason: String) {
        TuringAudioOffloadSignposts.assertNotMainThread("endRun")
        guard let directory = directoriesByRunID.removeValue(forKey: runID) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
        print("""
        [TuringAudioOffload] generated run removed
          runID: \(runID)
          reason: \(reason)
        """)
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !product.overflow else { return UInt64.max }
        let sum = product.partialValue.addingReportingOverflow(nanos)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}
