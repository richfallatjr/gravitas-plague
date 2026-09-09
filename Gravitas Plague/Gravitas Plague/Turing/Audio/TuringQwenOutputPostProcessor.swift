import AVFoundation
import Foundation

nonisolated enum TuringQwenOutputPostProcessor {
    private static let defaultRate = 0.85
    private static let disabledEnvironmentKey = "TURING_QWEN_OUTPUT_STRETCH_DISABLED"
    private static let rateEnvironmentKey = "TURING_QWEN_OUTPUT_STRETCH_RATE"

    static func processForPlayback(
        _ audio: TuringComputeGapGeneratedAudio,
        reason: String
    ) async -> TuringComputeGapGeneratedAudio {
        let rate = configuredRate
        guard shouldProcess(rate: rate) else {
            logBypassed(
                reason: reason,
                segmentIndex: audio.segmentIndex,
                rate: rate,
                sampleCount: audio.samples.count,
                sampleRate: audio.sampleRate,
                channelCount: audio.channelCount
            )
            return audio
        }

        let segmentIndex = audio.segmentIndex
        let sampleRate = audio.sampleRate
        let channelCount = audio.channelCount
        let samples = audio.samples

        let started = Date()
        let processedSamples = await Task.detached(priority: .userInitiated) {
            stretch(
                samples: samples,
                channelCount: Int(channelCount),
                rate: rate
            )
        }.value
        let elapsed = Date().timeIntervalSince(started)

        let inputDuration = durationSeconds(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let outputDuration = durationSeconds(
            sampleCount: processedSamples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        print("""
        [TuringQwenPostProcess] output time stretch applied
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          inputSampleCount: \(samples.count)
          outputSampleCount: \(processedSamples.count)
          inputDurationSeconds: \(String(format: "%.3f", inputDuration))
          outputDurationSeconds: \(String(format: "%.3f", outputDuration))
          processingSeconds: \(String(format: "%.3f", elapsed))
        """)

        return TuringComputeGapGeneratedAudio(
            segmentIndex: segmentIndex,
            samples: processedSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceText: audio.sourceText
        )
    }

    static func processForPlayback(
        _ audio: TuringComputeGapGeneratedAudio,
        policy: TuringQwenOutputProcessingPolicy,
        reason: String
    ) async -> TuringComputeGapGeneratedAudio {
        let rate = policy.playbackRate

        guard shouldProcess(rate: rate) else {
            logBypassed(
                reason: reason,
                segmentIndex: audio.segmentIndex,
                rate: rate,
                sampleCount: audio.samples.count,
                sampleRate: audio.sampleRate,
                channelCount: audio.channelCount
            )

            print("""
            [TuringQwenPostProcess] voice policy bypassed
              voiceID: \(policy.voiceID)
              rate: \(String(format: "%.3f", rate))
              segmentIndex: \(audio.segmentIndex)
            """)

            return audio
        }

        let segmentIndex = audio.segmentIndex
        let sampleRate = audio.sampleRate
        let channelCount = audio.channelCount
        let samples = audio.samples
        let started = Date()

        let processedSamples = await Task.detached(
            priority: .userInitiated
        ) {
            stretch(
                samples: samples,
                channelCount: Int(channelCount),
                rate: rate
            )
        }.value

        let elapsed = Date().timeIntervalSince(started)
        let inputDuration = durationSeconds(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let outputDuration = durationSeconds(
            sampleCount: processedSamples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        print("""
        [TuringQwenPostProcess] voice policy applied
          voiceID: \(policy.voiceID)
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          inputSampleCount: \(samples.count)
          outputSampleCount: \(processedSamples.count)
          inputDurationSeconds: \(String(format: "%.3f", inputDuration))
          outputDurationSeconds: \(String(format: "%.3f", outputDuration))
          processingSeconds: \(String(format: "%.3f", elapsed))
        """)

        return TuringComputeGapGeneratedAudio(
            segmentIndex: segmentIndex,
            samples: processedSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceText: audio.sourceText
        )
    }

    static func processSamplesForPlayback(
        samples: [Float],
        sampleRate: Int,
        channelCount: Int = 1,
        segmentIndex: Int,
        reason: String
    ) async -> [Float] {
        let rate = configuredRate
        guard shouldProcess(rate: rate) else {
            logBypassed(
                reason: reason,
                segmentIndex: segmentIndex,
                rate: rate,
                sampleCount: samples.count,
                sampleRate: Double(sampleRate),
                channelCount: AVAudioChannelCount(channelCount)
            )
            return samples
        }

        let started = Date()
        let processedSamples = await Task.detached(priority: .userInitiated) {
            stretch(
                samples: samples,
                channelCount: channelCount,
                rate: rate
            )
        }.value
        let elapsed = Date().timeIntervalSince(started)

        let inputDuration = durationSeconds(
            sampleCount: samples.count,
            sampleRate: Double(sampleRate),
            channelCount: AVAudioChannelCount(channelCount)
        )
        let outputDuration = durationSeconds(
            sampleCount: processedSamples.count,
            sampleRate: Double(sampleRate),
            channelCount: AVAudioChannelCount(channelCount)
        )

        print("""
        [TuringQwenPostProcess] output time stretch applied
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          inputSampleCount: \(samples.count)
          outputSampleCount: \(processedSamples.count)
          inputDurationSeconds: \(String(format: "%.3f", inputDuration))
          outputDurationSeconds: \(String(format: "%.3f", outputDuration))
          processingSeconds: \(String(format: "%.3f", elapsed))
        """)

        return processedSamples
    }

    private static var configuredRate: Double {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment[rateEnvironmentKey],
           let parsed = Double(value),
           parsed > 0.25,
           parsed <= 2.0 {
            return parsed
        }
        return defaultRate
    }

    private static func shouldProcess(rate: Double) -> Bool {
        let disabled = ProcessInfo.processInfo.environment[disabledEnvironmentKey] ?? ""
        guard disabled != "1",
              disabled.lowercased() != "true" else {
            return false
        }

        return abs(rate - 1.0) > 0.001
    }

    private static func durationSeconds(
        sampleCount: Int,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> Double {
        guard sampleRate > 0,
              channelCount > 0 else {
            return 0
        }
        return Double(sampleCount) / Double(channelCount) / sampleRate
    }

    private static func logBypassed(
        reason: String,
        segmentIndex: Int,
        rate: Double,
        sampleCount: Int,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) {
        let disabled = ProcessInfo.processInfo.environment[disabledEnvironmentKey] ?? ""
        let duration = durationSeconds(
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        print("""
        [TuringQwenPostProcess] output time stretch bypassed
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          disabledEnv: \(disabled.isEmpty ? "<unset>" : disabled)
          sampleCount: \(sampleCount)
          durationSeconds: \(String(format: "%.3f", duration))
        """)
    }

    private static func stretch(
        samples: [Float],
        channelCount: Int,
        rate: Double
    ) -> [Float] {
        TuringQwenDeterministicTimeStretcher.stretch(
            samples: samples,
            channelCount: channelCount,
            rate: rate
        )
    }
}
