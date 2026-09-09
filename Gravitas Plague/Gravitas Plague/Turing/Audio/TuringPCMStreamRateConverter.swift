import AVFoundation
import Foundation

/// Stateful producer-side conversion into RealityKit's fixed 48 kHz generator
/// format. This object is owned by the serialized PCM producer; it is never
/// touched by RealityKit's real-time render callback.
nonisolated final class TuringPCMStreamRateConverter: @unchecked Sendable {
    private static let outputSampleRate =
        TuringPCMStreamConfiguration.realityKitSampleRate
    private static let drainFrameCapacity = 4_096
    private static let maximumDrainIterations = 128

    private let sourceFormat: AVAudioFormat
    private let destinationFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var finished = false

    init(sourceSampleRate: Int) throws {
        guard sourceSampleRate > 0,
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sourceSampleRate),
                channels: 1,
                interleaved: false
              ),
              let destinationFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(Self.outputSampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(
                from: sourceFormat,
                to: destinationFormat
              ) else {
            throw TuringPCMStreamError.invalidConfiguration(
                "Could not create the mono Float32 sample-rate converter."
            )
        }
        self.sourceFormat = sourceFormat
        self.destinationFormat = destinationFormat
        self.converter = converter
        converter.primeMethod = .normal
    }

    func convert(_ samples: [Float]) throws -> ContiguousArray<Float> {
        guard !finished else {
            throw TuringPCMStreamError.appendAfterSeal
        }
        guard !samples.isEmpty else { return [] }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let inputChannel = input.floatChannelData?[0] else {
            throw TuringPCMStreamError.conversionFailed(
                "Could not allocate the input PCM buffer."
            )
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let sourceAddress = source.baseAddress else { return }
            for index in source.indices {
                let value = sourceAddress[index]
                inputChannel[index] = value.isFinite
                    ? max(-1, min(1, value))
                    : 0
            }
        }

        let ratio = destinationFormat.sampleRate / sourceFormat.sampleRate
        let expectedFrames = Int(
            ceil(Double(samples.count) * ratio)
        )
        let capacity = max(
            1,
            expectedFrames + Int(converter.primeInfo.trailingFrames) + 64
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: AVAudioFrameCount(capacity)
        ) else {
            throw TuringPCMStreamError.conversionFailed(
                "Could not allocate the output PCM buffer."
            )
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw TuringPCMStreamError.conversionFailed(
                conversionError.localizedDescription
            )
        }
        guard status == .haveData || status == .inputRanDry,
              let outputChannel = output.floatChannelData?[0] else {
            throw TuringPCMStreamError.conversionFailed(
                "Unexpected converter status \(status.rawValue)."
            )
        }
        return sanitizedSamples(
            outputChannel,
            count: Int(output.frameLength)
        )
    }

    func finish() throws -> ContiguousArray<Float> {
        guard !finished else { return [] }
        finished = true

        var result = ContiguousArray<Float>()
        result.reserveCapacity(Self.drainFrameCapacity)
        var suppliedEndOfStream = false

        for _ in 0..<Self.maximumDrainIterations {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: destinationFormat,
                frameCapacity: AVAudioFrameCount(
                    Self.drainFrameCapacity
                )
            ) else {
                throw TuringPCMStreamError.conversionFailed(
                    "Could not allocate a drain PCM buffer."
                )
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                suppliedEndOfStream = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw TuringPCMStreamError.conversionFailed(
                    conversionError.localizedDescription
                )
            }
            if let channel = output.floatChannelData?[0],
               output.frameLength > 0 {
                result.append(
                    contentsOf: sanitizedSamples(
                        channel,
                        count: Int(output.frameLength)
                    )
                )
            }
            switch status {
            case .endOfStream:
                return result
            case .inputRanDry where suppliedEndOfStream && output.frameLength == 0:
                return result
            case .haveData, .inputRanDry:
                continue
            case .error:
                throw TuringPCMStreamError.conversionFailed(
                    "Converter returned an error while draining."
                )
            @unknown default:
                throw TuringPCMStreamError.conversionFailed(
                    "Converter returned an unknown status while draining."
                )
            }
        }
        throw TuringPCMStreamError.conversionFailed(
            "Converter did not finish within the bounded drain iteration limit."
        )
    }

    private func sanitizedSamples(
        _ source: UnsafePointer<Float>,
        count: Int
    ) -> ContiguousArray<Float> {
        var result = ContiguousArray<Float>()
        result.reserveCapacity(count)
        for index in 0..<count {
            let value = source[index]
            result.append(
                value.isFinite ? max(-1, min(1, value)) : 0
            )
        }
        return result
    }
}
