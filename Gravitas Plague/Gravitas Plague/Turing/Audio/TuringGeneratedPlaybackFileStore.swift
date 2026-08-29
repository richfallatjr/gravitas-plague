import AVFoundation
import Foundation

actor TuringGeneratedPlaybackFileStore {
    nonisolated enum GeneratedVisualAnalysisState: Sendable, Equatable {
        case ready(TuringGeneratedSpeechVisualAnalysis)
        case pending(TuringGeneratedSpeechAnalysisTicket)
        case unavailable(TuringGeneratedSpeechAnalysisUnavailableReason)
    }

    struct PreparedClip: Sendable, Equatable {
        let runID: String
        let segmentIndex: Int
        let fileURL: URL
        let frameCount: AVAudioFramePosition
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let analysisIdentity: TuringGeneratedSpeechAnalysisIdentity?
        let generatedVisualAnalysisState: GeneratedVisualAnalysisState

        var generatedVisualAnalysis: TuringGeneratedSpeechVisualAnalysis? {
            guard case .ready(let value) = generatedVisualAnalysisState else { return nil }
            return value
        }

        var generatedAnalysisTicket: TuringGeneratedSpeechAnalysisTicket? {
            guard case .pending(let value) = generatedVisualAnalysisState else { return nil }
            return value
        }

        var generatedVisualAnalysisStatus: TuringGeneratedSpeechAnalysisUnavailableReason? {
            guard case .unavailable(let value) = generatedVisualAnalysisState else { return nil }
            return value
        }

        var generatedVisualAnalysisNanoseconds: UInt64? {
            generatedVisualAnalysis?.envelope.diagnostics.analysisNanoseconds
        }

        func replacingVisualAnalysis(
            _ analysis: TuringGeneratedSpeechVisualAnalysis
        ) -> PreparedClip {
            PreparedClip(
                runID: runID,
                segmentIndex: segmentIndex,
                fileURL: fileURL,
                frameCount: frameCount,
                sampleRate: sampleRate,
                channelCount: channelCount,
                analysisIdentity: analysisIdentity,
                generatedVisualAnalysisState: .ready(analysis)
            )
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.runID == rhs.runID &&
                lhs.segmentIndex == rhs.segmentIndex &&
                lhs.fileURL == rhs.fileURL &&
                lhs.frameCount == rhs.frameCount &&
                lhs.sampleRate == rhs.sampleRate &&
                lhs.channelCount == rhs.channelCount &&
                lhs.analysisIdentity == rhs.analysisIdentity &&
                lhs.generatedVisualAnalysisState == rhs.generatedVisualAnalysisState &&
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
    private let generatedSpeechAnalysisCoordinator: TuringGeneratedSpeechAnalysisCoordinator
    private var directoriesByRunID: [String: URL] = [:]

    init(
        rootURL: URL,
        generatedSpeechAnalysisCoordinator: TuringGeneratedSpeechAnalysisCoordinator = .shared
    ) {
        self.rootURL = rootURL
        self.generatedSpeechAnalysisCoordinator = generatedSpeechAnalysisCoordinator
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
        audio: TuringComputeGapGeneratedAudio,
        speakerCharacterID: TuringConversationCharacterID = .bigMike
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
        let analysisSubmission: TuringGeneratedSpeechAnalysisSubmission
        if MindEyeQualificationFeatureControl.isMindEyeEnabled {
            analysisSubmission = await generatedSpeechAnalysisCoordinator.submit(
                runID: runID,
                segmentIndex: segmentIndex,
                samples: audio.samples,
                sampleRate: sampleRate,
                channelCount: channelCountInt,
                speakerCharacterID: speakerCharacterID,
                sourceText: audio.sourceText
            )
            print(
                "[TuringGeneratedSpeech] analysisStart segmentIndex=\(segmentIndex) " +
                    "processedAudioSamples=\(audio.samples.count) sampleRate=\(sampleRate) " +
                    "channelCount=\(channelCountInt)"
            )
        } else {
            analysisSubmission = .rejected(.cancelled)
            print(
                "[TuringGeneratedSpeech] analysisSkipped segmentIndex=\(segmentIndex) " +
                    "reason=qualificationControlDisabled audioContinues=true"
            )
        }
        var wavSucceeded = false
        defer {
            if !wavSucceeded,
               case .accepted(let ticket) = analysisSubmission {
                Task { [generatedSpeechAnalysisCoordinator] in
                    await generatedSpeechAnalysisCoordinator.cancel(
                        identity: ticket.identity,
                        reason: "generatedWAVWriteFailed"
                    )
                }
            }
        }
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

        let analysisState: GeneratedVisualAnalysisState
        let analysisIdentity: TuringGeneratedSpeechAnalysisIdentity?
        switch analysisSubmission {
        case .accepted(let ticket):
            analysisIdentity = ticket.identity
            if let result = ticket.resultBox.resultIfReady() {
                switch result {
                case .ready(let analysis): analysisState = .ready(analysis)
                case .unavailable(let reason): analysisState = .unavailable(reason)
                }
            } else {
                analysisState = .pending(ticket)
            }
        case .rejected(let reason):
            analysisIdentity = nil
            analysisState = .unavailable(reason)
        }
        print(
            "[TuringGeneratedSpeech] WAV ready segmentIndex=\(segmentIndex) " +
                "addedAnalysisWaitNanoseconds=0"
        )
        wavSucceeded = true
        return PreparedClip(
            runID: runID,
            segmentIndex: segmentIndex,
            fileURL: finalURL,
            frameCount: validation.length,
            sampleRate: validation.fileFormat.sampleRate,
            channelCount: validation.fileFormat.channelCount,
            analysisIdentity: analysisIdentity,
            generatedVisualAnalysisState: analysisState
        )
    }

    func analysisEvents() async -> AsyncStream<TuringGeneratedSpeechAnalysisEvent> {
        await generatedSpeechAnalysisCoordinator.events()
    }

    func delete(_ clip: PreparedClip, reason: String) async {
        TuringAudioOffloadSignposts.assertNotMainThread("deleteGeneratedWAV")
        if let ticket = clip.generatedAnalysisTicket {
            await generatedSpeechAnalysisCoordinator.cancel(
                identity: ticket.identity,
                reason: reason
            )
        }
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

    func endRun(_ runID: String, reason: String) async {
        TuringAudioOffloadSignposts.assertNotMainThread("endRun")
        await generatedSpeechAnalysisCoordinator.cancelRun(
            runID: runID,
            reason: reason
        )
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
