import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativePhase5BenchmarkMatrixTests {
    @Test
    func modeConfigurationMapsOnlyImplementedStrategies() throws {
        let control = try TuringQwenNativePhase5ModeConfiguration(
            mode: .currentTwoLaneDefaultStreamControl
        )
        #expect(control.requestedLaneCount == 2)
        #expect(control.laneStreamMode == .defaultOnly)

        let single = try TuringQwenNativePhase5ModeConfiguration(
            mode: .singleLane
        )
        #expect(single.requestedLaneCount == 1)
        #expect(single.laneStreamMode == .defaultOnly)

        let dedicated = try TuringQwenNativePhase5ModeConfiguration(
            mode: .threeLanePerStream
        )
        #expect(dedicated.requestedLaneCount == 3)
        #expect(dedicated.laneStreamMode == .dedicatedGPU)

        #expect(throws: (any Error).self) {
            _ = try TuringQwenNativePhase5ModeConfiguration(
                mode: .microbatch2
            )
        }
    }

    @Test
    func matrixIsDeterministicHonestAndNeverPromotes() async throws {
        let recorder = Phase5ExecutedModeRecorder()
        let report = await TuringQwenNativePhase5BenchmarkMatrixRunner.runMatrix(
            label: "unit",
            suite: .quick,
            corpusDigest: "corpus",
            generatedAtUTC: "2026-09-07T00:00:00Z"
        ) { configuration in
            await recorder.append(configuration.mode)
            let values: (nextRequired: Double, anyFirst: Double, wall: Double)
            switch configuration.mode {
            case .currentTwoLaneDefaultStreamControl:
                values = (2.0, 1.0, 10.0)
            case .singleLane:
                values = (1.5, 1.2, 8.0)
            case .threeLaneDefaultStream:
                values = (2.5, 0.8, 12.0)
            case .twoLanePerStream:
                values = (1.8, 0.9, 9.0)
            case .threeLanePerStream:
                values = (1.9, 0.7, 9.5)
            case .microbatch2:
                Issue.record("Unsupported microbatch must not execute")
                values = (100, 100, 100)
            }
            return try observation(
                laneCount: configuration.requestedLaneCount,
                nextRequiredSeconds: values.nextRequired,
                anyFirstSeconds: values.anyFirst,
                wallSeconds: values.wall
            )
        }

        let executed = await recorder.snapshot()
        #expect(executed == [
            .currentTwoLaneDefaultStreamControl,
            .singleLane,
            .threeLaneDefaultStream,
            .twoLanePerStream,
            .threeLanePerStream
        ])
        #expect(report.results.count == 6)
        #expect(report.results.last?.mode == .microbatch2)
        #expect(report.results.last?.status == .unsupported)
        #expect(report.matrixScope == "isolatedRawLaneTopologyApproximation")
        #expect(!report.exactShippingControlExecuted)
        #expect(report.promotionStatus == .notEvaluated)
        #expect(!report.automaticPromotionPerformed)
        #expect(!report.shippingTopologyChanged)

        let singleComparison = try #require(
            report.metricComparisonsToApproximateControl.first {
                $0.candidateMode == .singleLane
            }
        )
        #expect(singleComparison.nextRequiredPCMDeltaSeconds.value == -0.5)
        #expect(singleComparison.nextRequiredPCMIsNeutralOrBetter.value == true)
        #expect(
            singleComparison.aggregateThroughputIsNeutralOrBetter.value == true
        )

        let threeDefaultComparison = try #require(
            report.metricComparisonsToApproximateControl.first {
                $0.candidateMode == .threeLaneDefaultStream
            }
        )
        #expect(
            threeDefaultComparison.nextRequiredPCMIsNeutralOrBetter.value ==
                false
        )
        #expect(
            threeDefaultComparison.aggregateThroughputIsNeutralOrBetter.value ==
                false
        )

        let encoded = try JSONEncoder().encode(report)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["automaticPromotionPerformed"] as? Bool == false)
        #expect(json["exactShippingControlExecuted"] as? Bool == false)
    }

    @Test
    func firstSupportedFailureStopsFurtherMLXModes() async {
        let recorder = Phase5ExecutedModeRecorder()
        let report = await TuringQwenNativePhase5BenchmarkMatrixRunner.runMatrix(
            label: "failure",
            suite: .quick,
            corpusDigest: "corpus",
            generatedAtUTC: "2026-09-07T00:00:00Z"
        ) { configuration in
            await recorder.append(configuration.mode)
            throw Phase5SyntheticError.failed
        }

        #expect(await recorder.snapshot() == [
            .currentTwoLaneDefaultStreamControl
        ])
        #expect(report.results[0].status == .failed)
        #expect(report.results[1].status == .notRun)
        #expect(report.results[2].status == .notRun)
        #expect(report.results[3].status == .notRun)
        #expect(report.results[4].status == .notRun)
        #expect(report.results[5].status == .unsupported)
        #expect(report.supportedModeFailureCount == 5)
    }

    @Test
    func observationRequiresOneDigestForEveryCompletedSegment() {
        #expect(throws: (any Error).self) {
            _ = try TuringQwenNativePhase5ModeObservation(
                actualLaneCount: 1,
                firstPCMSeconds: 1,
                firstCompletedSegmentSeconds: 1,
                aggregateGeneratedAudioSeconds: 1,
                aggregateWallSeconds: 1,
                expectedSegmentCount: 1,
                completedSegmentIndices: [1],
                perSegmentPCMDigests: [:],
                nonemptyAudioForEveryCompletedSegment: true,
                consistentSampleRate: 24_000
            )
        }
    }

    private func observation(
        laneCount: Int,
        nextRequiredSeconds: Double,
        anyFirstSeconds: Double,
        wallSeconds: Double
    ) throws -> TuringQwenNativePhase5ModeObservation {
        try .init(
            actualLaneCount: laneCount,
            firstPCMSeconds: nextRequiredSeconds,
            firstCompletedSegmentSeconds: anyFirstSeconds,
            aggregateGeneratedAudioSeconds: 10,
            aggregateWallSeconds: wallSeconds,
            expectedSegmentCount: 1,
            completedSegmentIndices: [1],
            perSegmentPCMDigests: [1: "pcm-1"],
            nonemptyAudioForEveryCompletedSegment: true,
            consistentSampleRate: 24_000,
            currentPhysicalFootprintMB: 100,
            currentResidentSizeMB: 90,
            postRunMLXActiveMemoryMB: 80,
            postRunMLXCacheMemoryMB: 10,
            mlxCacheLimitMB: 1_024,
            memoryGuardDowngraded: false,
            schedulerReportedUnderrunCount: 0
        )
    }
}

private actor Phase5ExecutedModeRecorder {
    private var modes: [TuringQwenNativePhase5QualificationMode] = []

    func append(_ mode: TuringQwenNativePhase5QualificationMode) {
        modes.append(mode)
    }

    func snapshot() -> [TuringQwenNativePhase5QualificationMode] {
        modes
    }
}

private enum Phase5SyntheticError: Error {
    case failed
}
