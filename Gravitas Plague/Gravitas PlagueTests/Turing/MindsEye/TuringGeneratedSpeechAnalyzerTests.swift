import XCTest

@testable import Gravitas_Plague

final class TuringGeneratedSpeechAnalyzerTests: XCTestCase {
    private let analyzer = TuringGeneratedSpeechAnalyzer()

    func testSilenceProducesOnlyRestWithFiniteDiagnostics() throws {
        let analysis = try analyzer.analyze(
            processedAudio: Array(repeating: 0, count: 32_000),
            sampleRate: 16_000,
            channelCount: 1,
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        XCTAssertEqual(analysis.frameTrack.frameCount, 120)
        XCTAssertTrue(analysis.frameTrack.poseRuns.allSatisfy { $0.pose == .rest })
        XCTAssertEqual(analysis.envelope.diagnostics.speechBucketCount, 0)
        XCTAssertEqual(analysis.envelope.diagnostics.roundAccentCount, 0)
        XCTAssertEqual(analysis.envelope.diagnostics.teethAccentCount, 0)
        XCTAssertTrue(analysis.envelope.diagnostics.floorDecibels.isFinite)
        XCTAssertTrue(analysis.envelope.diagnostics.ceilingDecibels.isFinite)
    }

    func testNonfiniteClippingAndStereoDownmixAreSanitized() throws {
        let sanitized = try TuringGeneratedSpeechPCM.sanitizeAndDownmix(
            interleaved: [.nan, 1.5, .infinity, -2, 0.5, 0.5],
            channelCount: 2
        )
        XCTAssertEqual(sanitized.nonfiniteCount, 2)
        XCTAssertEqual(sanitized.clippedCount, 2)
        XCTAssertEqual(sanitized.samples.count, 3)
        XCTAssertTrue(sanitized.samples.allSatisfy(\.isFinite))
        XCTAssertEqual(sanitized.samples[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(sanitized.samples[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(sanitized.samples[2], 0.5, accuracy: 0.0001)
    }

    func testSpeechPauseSpeechContainsAConfirmedRestBarrier() throws {
        let rate = 16_000
        var samples = Array(repeating: Float.zero, count: rate / 3)
        samples += tone(sampleRate: rate, sampleCount: rate / 2, frequency: 180, amplitude: 0.12)
        samples += Array(repeating: Float.zero, count: rate / 3)
        samples += tone(sampleRate: rate, sampleCount: rate / 2, frequency: 240, amplitude: 0.22)
        samples += Array(repeating: Float.zero, count: rate / 4)
        let analysis = try analyzer.analyze(
            processedAudio: samples,
            sampleRate: rate,
            channelCount: 1,
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        let poses = analysis.envelope.buckets.map(\.semanticPose)
        XCTAssertTrue(poses.contains { $0 != .rest })
        let midpoint = poses.count / 2
        XCTAssertTrue(poses[max(0, midpoint - 2)...min(poses.count - 1, midpoint + 2)].contains(.rest))
    }

    func testArbitrarySampleRatesUseExactCeilingFrameMath() throws {
        for rate in [16_000, 22_050, 24_000, 44_100, 48_000] {
            let sampleCount = rate + 1
            let analysis = try analyzer.analyze(
                processedAudio: Array(repeating: 0, count: sampleCount),
                sampleRate: rate,
                channelCount: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(2))
            )
            XCTAssertEqual(analysis.frameTrack.frameCount, 61, "sampleRate=\(rate)")
            XCTAssertEqual(analysis.frameTrack.poseRuns.first?.startFrame, 0)
            XCTAssertEqual(analysis.frameTrack.poseRuns.last?.endFrameExclusive, 61)
        }
    }

    func testAnalysisIsDeterministicApartFromMeasuredDuration() throws {
        let samples = tone(sampleRate: 16_000, sampleCount: 24_000, frequency: 210, amplitude: 0.15)
        let first = try analyzer.analyze(
            processedAudio: samples,
            sampleRate: 16_000,
            channelCount: 1,
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        let second = try analyzer.analyze(
            processedAudio: samples,
            sampleRate: 16_000,
            channelCount: 1,
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        XCTAssertEqual(first.frameTrack, second.frameTrack)
        XCTAssertEqual(first.envelope.buckets, second.envelope.buckets)
    }

    func testExpiredDeadlineStopsVisualAnalysis() {
        XCTAssertThrowsError(try analyzer.analyze(
            processedAudio: Array(repeating: 0.1, count: 160_000),
            sampleRate: 16_000,
            channelCount: 1,
            deadline: ContinuousClock.now
        )) { error in
            XCTAssertEqual(error as? TuringGeneratedSpeechAnalysisError, .deadlineExceeded)
        }
    }

    private func tone(
        sampleRate: Int,
        sampleCount: Int,
        frequency: Float,
        amplitude: Float
    ) -> [Float] {
        (0..<sampleCount).map { index in
            amplitude * sin(2 * .pi * frequency * Float(index) / Float(sampleRate))
        }
    }
}
