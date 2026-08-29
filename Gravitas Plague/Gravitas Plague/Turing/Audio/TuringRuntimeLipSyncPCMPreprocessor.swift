import AVFoundation
import Foundation

nonisolated struct TuringRuntimeLipSyncPCMPreprocessor: Sendable {
    static let alignmentSampleRate = 16_000

    func prepare(
        input: TuringRuntimeLipSyncInput,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringRuntimeLipSyncPreparedPCM {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !cancellation.isCancelled else {
            throw TuringRuntimeLipSyncFailure.cancelled
        }
        var sanitized = ContiguousArray<Float>()
        sanitized.reserveCapacity(input.interleavedPCM.count)
        for sample in input.interleavedPCM {
            guard !cancellation.isCancelled else {
                throw TuringRuntimeLipSyncFailure.cancelled
            }
            sanitized.append(sample.isFinite ? max(-1, min(1, sample)) : 0)
        }
        let sourceHash = TuringRuntimeLipSyncSHA256.sanitizedPCM(
            sanitized,
            sampleRate: input.sampleRate,
            channelCount: input.channelCount
        )
        var mono = ContiguousArray<Float>(
            repeating: 0,
            count: input.sampleCountPerChannel
        )
        for frame in 0..<input.sampleCountPerChannel {
            var sum: Float = 0
            let offset = frame * input.channelCount
            for channel in 0..<input.channelCount {
                sum += sanitized[offset + channel]
            }
            mono[frame] = sum / Float(input.channelCount)
        }
        let resampled = try resample(
            mono,
            sourceSampleRate: input.sampleRate,
            cancellation: cancellation
        )
        var pcm16 = ContiguousArray<Int16>()
        pcm16.reserveCapacity(resampled.count)
        for sample in resampled {
            let scaled = Double(max(-1, min(1, sample))) * 32_767
            pcm16.append(Int16(clamping: Int(scaled.rounded(.toNearestOrAwayFromZero))))
        }
        guard !pcm16.isEmpty else {
            throw TuringRuntimeLipSyncFailure.preprocessingFailed(
                "PCM resampler produced no alignment samples."
            )
        }
        return .init(
            sourceSampleRate: input.sampleRate,
            sourceChannelCount: input.channelCount,
            sourceSampleCountPerChannel: input.sampleCountPerChannel,
            sourcePCM_SHA256: sourceHash,
            alignmentSampleRate: Self.alignmentSampleRate,
            monoPCM16: pcm16
        )
    }

    private func resample(
        _ mono: ContiguousArray<Float>,
        sourceSampleRate: Int,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> ContiguousArray<Float> {
        if sourceSampleRate == Self.alignmentSampleRate { return mono }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceSampleRate),
            channels: 1,
            interleaved: false
        ), let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.alignmentSampleRate),
            channels: 1,
            interleaved: false
        ), let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(mono.count)
        ), let converter = AVAudioConverter(
            from: sourceFormat,
            to: destinationFormat
        ), let sourceChannels = sourceBuffer.floatChannelData else {
            throw TuringRuntimeLipSyncFailure.preprocessingFailed(
                "AVAudioConverter setup failed."
            )
        }
        sourceBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { source in
            sourceChannels[0].update(from: source.baseAddress!, count: mono.count)
        }
        let expected = Int(ceil(
            Double(mono.count) * Double(Self.alignmentSampleRate) /
                Double(sourceSampleRate)
        ))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: AVAudioFrameCount(expected + 64)
        ) else {
            throw TuringRuntimeLipSyncFailure.preprocessingFailed(
                "AVAudioConverter output allocation failed."
            )
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            if cancellation.isCancelled {
                inputStatus.pointee = .noDataNow
                return nil
            }
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard !cancellation.isCancelled else {
            throw TuringRuntimeLipSyncFailure.cancelled
        }
        guard status == .haveData || status == .endOfStream,
              conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            throw TuringRuntimeLipSyncFailure.preprocessingFailed(
                conversionError?.localizedDescription ?? "AVAudioConverter failed."
            )
        }
        let count = Int(output.frameLength)
        let actualDuration = Double(count) / Double(Self.alignmentSampleRate)
        let sourceDuration = Double(mono.count) / Double(sourceSampleRate)
        guard abs(actualDuration - sourceDuration) <=
                (2.0 / Double(Self.alignmentSampleRate)) else {
            throw TuringRuntimeLipSyncFailure.preprocessingFailed(
                "Resampled duration exceeded the one-sample-plus-priming tolerance."
            )
        }
        return ContiguousArray(UnsafeBufferPointer(start: channel, count: count))
    }
}
