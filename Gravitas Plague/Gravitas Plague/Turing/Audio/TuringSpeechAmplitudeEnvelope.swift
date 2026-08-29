import Foundation

nonisolated struct TuringSpeechFeatureWindow: Sendable, Equatable {
    let startSample: Int
    let endSample: Int
    let rms: Float
    let decibelsFullScale: Float
    let peak: Float
    let zeroCrossingRate: Float
    let firstDifferenceRatio: Float
    let smoothedEnergy: Float
    let speechActive: Bool
}

nonisolated struct TuringSpeechAmplitudeEnvelopeBucket: Sendable, Equatable {
    let bucketIndex: Int
    let startSample: Int
    let endSample: Int
    let normalizedEnergy: Float
    let meanZeroCrossingRate: Float
    let meanFirstDifferenceRatio: Float
    let speechCoverage: Float
    let speechActive: Bool
    let semanticPose: TuringGeneratedMouthPose
}

nonisolated struct TuringGeneratedSpeechAnalysisDiagnostics: Sendable, Equatable {
    let sourceSampleRate: Int
    let sourceChannelCount: Int
    let interleavedSampleCount: Int
    let monoSampleCount: Int
    let sanitizedNonfiniteSampleCount: Int
    let clippedSampleCount: Int
    let featureWindowSamples: Int
    let featureHopSamples: Int
    let featureWindowCount: Int
    let envelopeBucketCount: Int
    let floorDecibels: Float
    let ceilingDecibels: Float
    let gateOpenDecibels: Float
    let gateCloseDecibels: Float
    let speechBucketCount: Int
    let silenceBucketCount: Int
    let roundAccentCount: Int
    let teethAccentCount: Int
    let generatedFrameCount: Int
    let poseRunCount: Int
    let analysisNanoseconds: UInt64
    let deadlineExceeded: Bool
}

nonisolated struct TuringSpeechAmplitudeEnvelope: Sendable, Equatable {
    let sampleRate: Int
    let sampleCount: Int
    let bucketRate: Int
    let buckets: ContiguousArray<TuringSpeechAmplitudeEnvelopeBucket>
    let diagnostics: TuringGeneratedSpeechAnalysisDiagnostics
}
