import Foundation

nonisolated struct TuringRuntimeLipSyncDiagnostics:
    Codable,
    Sendable,
    Equatable
{
    let exactTextPresent: Bool
    let normalizedWordCount: Int
    let unresolvedWordCount: Int
    let phoneSegmentCount: Int
    let alignmentFrameRate: Int
    let globalBoundaryOffsetFrames: Int
    let queueDelayNanoseconds: UInt64
    let engineColdStartNanoseconds: UInt64?
    let preprocessingNanoseconds: UInt64
    let firstPassNanoseconds: UInt64?
    let secondPassNanoseconds: UInt64?
    let mappingNanoseconds: UInt64
    let totalAnalysisNanoseconds: UInt64
    let fallbackReason: String?

    static let empty = Self(
        exactTextPresent: false,
        normalizedWordCount: 0,
        unresolvedWordCount: 0,
        phoneSegmentCount: 0,
        alignmentFrameRate: 100,
        globalBoundaryOffsetFrames: 0,
        queueDelayNanoseconds: 0,
        engineColdStartNanoseconds: nil,
        preprocessingNanoseconds: 0,
        firstPassNanoseconds: nil,
        secondPassNanoseconds: nil,
        mappingNanoseconds: 0,
        totalAnalysisNanoseconds: 0,
        fallbackReason: nil
    )
}

/// Sparse semantic mouth poses for one generated TTS segment.
nonisolated struct TuringRuntimeLipSyncManifest:
    Codable,
    Sendable,
    Equatable
{
    static let currentSchemaVersion = 1
    static let requiredFramesPerSecond = 60

    let schemaVersion: Int
    let generatorID: String
    let generatorVersion: String
    let quality: TuringRuntimeLipSyncQuality
    let identity: TuringGeneratedSpeechSegmentIdentity?
    let sourcePCM_SHA256: String?
    let sampleRate: Int
    let sampleCount: Int
    let framesPerSecond: Int
    let frameCount: Int
    let poseRuns: [TuringGeneratedMouthPoseRun]
    let diagnostics: TuringRuntimeLipSyncDiagnostics

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatorID: String = "test-runtime-generator",
        generatorVersion: String = "1",
        quality: TuringRuntimeLipSyncQuality = .forcedTextPhones,
        identity: TuringGeneratedSpeechSegmentIdentity? = nil,
        sourcePCM_SHA256: String? = nil,
        sampleRate: Int,
        sampleCount: Int,
        framesPerSecond: Int = Self.requiredFramesPerSecond,
        frameCount: Int? = nil,
        poseRuns: [TuringGeneratedMouthPoseRun],
        diagnostics: TuringRuntimeLipSyncDiagnostics = .empty
    ) {
        self.schemaVersion = schemaVersion
        self.generatorID = generatorID
        self.generatorVersion = generatorVersion
        self.quality = quality
        self.identity = identity
        self.sourcePCM_SHA256 = sourcePCM_SHA256
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.framesPerSecond = framesPerSecond
        self.frameCount = frameCount ?? (try? TuringGeneratedSpeechFrameTrack.frameCount(
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            framesPerSecond: framesPerSecond
        )) ?? 0
        self.poseRuns = poseRuns
        self.diagnostics = diagnostics
    }
}

/// Exact final playback PCM and authoritative Qwen text for one segment.
nonisolated struct TuringRuntimeLipSyncSegment: Sendable {
    let identity: TuringGeneratedSpeechAnalysisIdentity
    let speakerCharacterID: TuringConversationCharacterID
    let sourceText: String?
    let sourceTextSHA256: String
    let processedAudio: [Float]
    let sampleRate: Int
    let channelCount: Int

    init(
        identity: TuringGeneratedSpeechAnalysisIdentity,
        speakerCharacterID: TuringConversationCharacterID = .bigMike,
        sourceText: String?,
        sourceTextSHA256: String? = nil,
        processedAudio: [Float],
        sampleRate: Int,
        channelCount: Int
    ) {
        self.identity = identity
        self.speakerCharacterID = speakerCharacterID
        self.sourceText = sourceText
        self.sourceTextSHA256 = sourceTextSHA256 ??
            TuringRuntimeLipSyncSHA256.text(sourceText ?? "")
        self.processedAudio = processedAudio
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    var sampleCountPerChannel: Int {
        processedAudio.count / max(1, channelCount)
    }

    var segmentIdentity: TuringGeneratedSpeechSegmentIdentity {
        .init(
            runID: identity.runID,
            segmentIndex: identity.segmentIndex,
            speakerCharacterID: speakerCharacterID,
            sourceTextSHA256: sourceTextSHA256
        )
    }
}

/// Injected production generator. Calls are serialized by the existing worker.
nonisolated protocol TuringRuntimeLipSyncManifestGenerating: Sendable {
    var generatorID: String { get }
    var generatorVersion: String { get }

    func generateManifest(
        for segment: TuringRuntimeLipSyncSegment,
        deadline: ContinuousClock.Instant,
        cancellationToken: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringRuntimeLipSyncManifest

    func unload(reason: String)
}

nonisolated extension TuringRuntimeLipSyncManifestGenerating {
    func unload(reason: String) {}
}

nonisolated enum TuringRuntimeLipSyncManifestError:
    Error,
    Sendable,
    Equatable
{
    case cancelled
    case deadlineExceeded
    case invalidManifest
}

nonisolated enum TuringRuntimeLipSyncManifestAdapter {
    static func makeVisualAnalysis(
        manifest: TuringRuntimeLipSyncManifest,
        segment: TuringRuntimeLipSyncSegment,
        analysisNanoseconds: UInt64
    ) throws -> TuringGeneratedSpeechVisualAnalysis {
        let track = try makeFrameTrack(manifest: manifest, segment: segment)
        return TuringGeneratedSpeechVisualAnalysis(
            envelope: makeCompatibilityEnvelope(
                track: track,
                segment: segment,
                analysisNanoseconds: analysisNanoseconds
            ),
            frameTrack: track,
            quality: manifest.quality,
            generatorID: manifest.generatorID,
            sourcePCM_SHA256: manifest.sourcePCM_SHA256
        )
    }

    static func makeFrameTrack(
        manifest: TuringRuntimeLipSyncManifest,
        segment: TuringRuntimeLipSyncSegment
    ) throws -> TuringGeneratedSpeechFrameTrack {
        let expectedSampleCount = segment.sampleCountPerChannel
        guard manifest.schemaVersion ==
                TuringRuntimeLipSyncManifest.currentSchemaVersion,
              manifest.framesPerSecond ==
                TuringRuntimeLipSyncManifest.requiredFramesPerSecond,
              manifest.sampleRate == segment.sampleRate,
              manifest.sampleCount == expectedSampleCount,
              segment.sampleRate > 0,
              expectedSampleCount > 0,
              !manifest.generatorID.isEmpty,
              !manifest.generatorVersion.isEmpty,
              !manifest.poseRuns.isEmpty else {
            throw TuringRuntimeLipSyncManifestError.invalidManifest
        }
        if let manifestIdentity = manifest.identity,
           manifestIdentity != segment.segmentIdentity {
            throw TuringRuntimeLipSyncManifestError.invalidManifest
        }
        if manifest.identity != nil {
            var sanitized = ContiguousArray<Float>()
            sanitized.reserveCapacity(segment.processedAudio.count)
            for sample in segment.processedAudio {
                sanitized.append(sample.isFinite ? max(-1, min(1, sample)) : 0)
            }
            let expectedPCMHash = TuringRuntimeLipSyncSHA256.sanitizedPCM(
                sanitized,
                sampleRate: segment.sampleRate,
                channelCount: segment.channelCount
            )
            guard manifest.sourcePCM_SHA256 == expectedPCMHash else {
                throw TuringRuntimeLipSyncManifestError.invalidManifest
            }
        }
        let frameCount = try TuringGeneratedSpeechFrameTrack.frameCount(
            sampleCount: expectedSampleCount,
            sampleRate: segment.sampleRate,
            framesPerSecond: manifest.framesPerSecond
        )
        guard manifest.frameCount == frameCount else {
            throw TuringRuntimeLipSyncManifestError.invalidManifest
        }
        var poseBits = ContiguousArray<UInt8>()
        poseBits.reserveCapacity(frameCount)
        var previousEnd = 0
        var previousPose: TuringGeneratedMouthPose?
        for run in manifest.poseRuns {
            guard run.startFrame == previousEnd,
                  run.endFrameExclusive > run.startFrame,
                  run.endFrameExclusive <= frameCount,
                  run.pose != previousPose else {
                throw TuringRuntimeLipSyncManifestError.invalidManifest
            }
            poseBits.append(
                contentsOf: repeatElement(run.pose.rawValue, count: run.frameCount)
            )
            previousEnd = run.endFrameExclusive
            previousPose = run.pose
        }
        guard previousEnd == frameCount, poseBits.count == frameCount else {
            throw TuringRuntimeLipSyncManifestError.invalidManifest
        }
        return try TuringGeneratedSpeechFrameTrack(
            sampleRate: segment.sampleRate,
            sampleCount: expectedSampleCount,
            framesPerSecond: manifest.framesPerSecond,
            poseBits: poseBits,
            poseRuns: ContiguousArray(manifest.poseRuns)
        )
    }

    static func makeFrameTrack(
        manifest: TuringRuntimeLipSyncManifest,
        expectedSampleRate: Int,
        expectedSampleCount: Int
    ) throws -> TuringGeneratedSpeechFrameTrack {
        let segment = TuringRuntimeLipSyncSegment(
            identity: .init(ticketID: UUID(), runID: "adapter", segmentIndex: 0),
            sourceText: nil,
            processedAudio: Array(repeating: 0, count: expectedSampleCount),
            sampleRate: expectedSampleRate,
            channelCount: 1
        )
        return try makeFrameTrack(manifest: manifest, segment: segment)
    }

    private static func makeCompatibilityEnvelope(
        track: TuringGeneratedSpeechFrameTrack,
        segment: TuringRuntimeLipSyncSegment,
        analysisNanoseconds: UInt64
    ) -> TuringSpeechAmplitudeEnvelope {
        let bucketRate = 10
        let bucketCount = max(
            1,
            (track.sampleCount * bucketRate + track.sampleRate - 1) /
                track.sampleRate
        )
        var buckets = ContiguousArray<TuringSpeechAmplitudeEnvelopeBucket>()
        buckets.reserveCapacity(bucketCount)
        for bucketIndex in 0..<bucketCount {
            let start = min(
                track.sampleCount,
                bucketIndex * track.sampleRate / bucketRate
            )
            let end = min(
                track.sampleCount,
                (bucketIndex + 1) * track.sampleRate / bucketRate
            )
            let frameIndex = min(
                track.frameCount - 1,
                start * track.framesPerSecond / track.sampleRate
            )
            let pose = track.pose(atFrame: frameIndex) ?? .rest
            let speechActive = pose != .rest
            buckets.append(.init(
                bucketIndex: bucketIndex,
                startSample: start,
                endSample: max(start + 1, end),
                normalizedEnergy: speechActive ? 1 : 0,
                meanZeroCrossingRate: 0,
                meanFirstDifferenceRatio: 0,
                speechCoverage: speechActive ? 1 : 0,
                speechActive: speechActive,
                semanticPose: pose
            ))
        }
        let speechCount = buckets.filter(\.speechActive).count
        let diagnostics = TuringGeneratedSpeechAnalysisDiagnostics(
            sourceSampleRate: segment.sampleRate,
            sourceChannelCount: segment.channelCount,
            interleavedSampleCount: segment.processedAudio.count,
            monoSampleCount: track.sampleCount,
            sanitizedNonfiniteSampleCount: 0,
            clippedSampleCount: 0,
            featureWindowSamples: 0,
            featureHopSamples: 0,
            featureWindowCount: 0,
            envelopeBucketCount: buckets.count,
            floorDecibels: -120,
            ceilingDecibels: 0,
            gateOpenDecibels: 0,
            gateCloseDecibels: 0,
            speechBucketCount: speechCount,
            silenceBucketCount: buckets.count - speechCount,
            roundAccentCount: buckets.filter { $0.semanticPose == .round }.count,
            teethAccentCount: buckets.filter { $0.semanticPose == .teeth }.count,
            generatedFrameCount: track.frameCount,
            poseRunCount: track.poseRuns.count,
            analysisNanoseconds: analysisNanoseconds,
            deadlineExceeded: false
        )
        return TuringSpeechAmplitudeEnvelope(
            sampleRate: track.sampleRate,
            sampleCount: track.sampleCount,
            bucketRate: bucketRate,
            buckets: buckets,
            diagnostics: diagnostics
        )
    }
}
