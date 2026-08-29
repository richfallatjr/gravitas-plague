import Foundation

nonisolated struct TuringRuntimeLipSyncInput: Sendable {
    let identity: TuringGeneratedSpeechSegmentIdentity
    let exactSourceText: String
    let interleavedPCM: [Float]
    let sampleRate: Int
    let channelCount: Int
    let sampleCountPerChannel: Int
    let queuedAt: ContinuousClock.Instant

    init(
        identity: TuringGeneratedSpeechSegmentIdentity,
        exactSourceText: String,
        interleavedPCM: [Float],
        sampleRate: Int,
        channelCount: Int,
        queuedAt: ContinuousClock.Instant
    ) throws {
        guard TuringRuntimeLipSyncSHA256.text(exactSourceText) ==
                identity.sourceTextSHA256,
              sampleRate > 0,
              channelCount > 0,
              !interleavedPCM.isEmpty,
              interleavedPCM.count % channelCount == 0 else {
            throw TuringRuntimeLipSyncFailure.invalidInput(
                "Runtime lip-sync input identity or PCM metadata is invalid."
            )
        }
        self.identity = identity
        self.exactSourceText = exactSourceText
        self.interleavedPCM = interleavedPCM
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleCountPerChannel = interleavedPCM.count / channelCount
        self.queuedAt = queuedAt
    }
}

nonisolated struct TuringRuntimeLipSyncPreparedPCM: Sendable, Equatable {
    let sourceSampleRate: Int
    let sourceChannelCount: Int
    let sourceSampleCountPerChannel: Int
    let sourcePCM_SHA256: String
    let alignmentSampleRate: Int
    let monoPCM16: ContiguousArray<Int16>
}

nonisolated struct TuringRuntimeLipSyncManifestIdentity:
    Sendable,
    Equatable,
    Hashable
{
    let segment: TuringGeneratedSpeechSegmentIdentity
    let sourcePCM_SHA256: String
    let generatorID: String
    let generatorVersion: String
}
