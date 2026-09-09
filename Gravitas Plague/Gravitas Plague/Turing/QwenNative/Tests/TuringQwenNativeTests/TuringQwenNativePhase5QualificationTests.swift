import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativePhase5QualificationTests {
    @Test
    func matrixContainsCurrentControlAndEveryRoadmapMode() {
        #expect(
            TuringQwenNativePhase5QualificationMode.allCases == [
                .currentTwoLaneDefaultStreamControl,
                .singleLane,
                .threeLaneDefaultStream,
                .twoLanePerStream,
                .threeLanePerStream,
                .microbatch2
            ]
        )

        #expect(
            TuringQwenNativePhase5QualificationMode
                .currentTwoLaneDefaultStreamControl
                .requestedLaneCount == 2
        )
        #expect(
            TuringQwenNativePhase5QualificationMode
                .currentTwoLaneDefaultStreamControl
                .executionStrategy == .defaultGPUStream
        )
        #expect(
            TuringQwenNativePhase5QualificationMode.singleLane
                .requestedLaneCount == 1
        )
        #expect(
            TuringQwenNativePhase5QualificationMode
                .threeLaneDefaultStream
                .requestedLaneCount == 3
        )
        #expect(
            TuringQwenNativePhase5QualificationMode.twoLanePerStream
                .executionStrategy == .perTaskGPUStream
        )
        #expect(
            TuringQwenNativePhase5QualificationMode.microbatch2
                .executionStrategy == .microbatch
        )
    }

    @Test
    func installedAPISupportsTaskStreamsButNotFakeMicrobatching() {
        let capabilities =
            TuringQwenNativePhase5CapabilitySet.installedMLXSwift

        #expect(capabilities.classify(.singleLane).isSupported)
        #expect(
            capabilities.classify(.currentTwoLaneDefaultStreamControl)
                .isSupported
        )
        #expect(capabilities.classify(.threeLaneDefaultStream).isSupported)
        #expect(capabilities.classify(.twoLanePerStream).isSupported)
        #expect(capabilities.classify(.threeLanePerStream).isSupported)

        let microbatch = capabilities.classify(.microbatch2)
        #expect(microbatch.isSupported == false)
        #expect(
            microbatch.missingCapabilities ==
                [.batchedKVCacheAndSampling]
        )
        #expect(
            capabilities.assessment(for: .perTaskGPUStreams)?
                .availability == .supported
        )
        #expect(
            capabilities.assessment(for: .batchedKVCacheAndSampling)?
                .evidence.contains("microbatch2") == true
        )
    }

    @Test
    func metricsCenterFirstAudioAndPreserveAggregateThroughput() throws {
        let metrics = try makeMetrics(
            mode: .currentTwoLaneDefaultStreamControl,
            firstPCMP50: 0.72,
            firstPCMP95: 0.94,
            firstSegmentP50: 4.1,
            firstSegmentP95: 4.8,
            audioSeconds: 60,
            wallSeconds: 30,
            stage4Overhead: 0.03
        )

        #expect(metrics.schemaVersion == 1)
        #expect(metrics.firstPCMSecondsP50 == 0.72)
        #expect(metrics.firstPCMSecondsP95 == 0.94)
        #expect(metrics.firstCompletedSegmentSecondsP50 == 4.1)
        #expect(metrics.firstCompletedSegmentSecondsP95 == 4.8)
        #expect(metrics.aggregateAudioSecondsPerWallSecond == 2)

        let encoded = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(
            TuringQwenNativePhase5QualificationMetrics.self,
            from: encoded
        )
        #expect(decoded == metrics)
    }

    @Test
    func invalidOrIncompleteMeasurementsCannotBecomeEvidence() throws {
        let context = try makeContext()

        #expect(throws: Error.self) {
            try TuringQwenNativePhase5QualificationMetrics(
                mode: .singleLane,
                context: context,
                completedRunCount: 0,
                stage4StreamingActive: true,
                firstPCMSecondsP50: 0.8,
                firstPCMSecondsP95: 0.7,
                firstCompletedSegmentSecondsP50: 4,
                firstCompletedSegmentSecondsP95: 5,
                aggregateGeneratedAudioSeconds: 0,
                aggregateGenerationWallSeconds: 0,
                stage4OverheadSecondsPerAudioSecond: 0.02,
                underrunCount: 0,
                missingSpeechCount: 0,
                duplicateSpeechCount: 0,
                reorderedSpeechCount: 0,
                speechQualityPassed: true,
                cloneIdentityPassed: true
            )
        }
    }

    @Test
    func eligibleCandidateStillRequiresAnExplicitProductionChange() throws {
        let control = try makeMetrics(
            mode: .currentTwoLaneDefaultStreamControl,
            firstPCMP50: 0.8,
            firstPCMP95: 1.0,
            firstSegmentP50: 4.0,
            firstSegmentP95: 5.0,
            audioSeconds: 60,
            wallSeconds: 40,
            stage4Overhead: 0.04
        )
        let candidate = try makeMetrics(
            mode: .twoLanePerStream,
            firstPCMP50: 0.6,
            firstPCMP95: 0.8,
            firstSegmentP50: 3.5,
            firstSegmentP95: 4.3,
            audioSeconds: 72,
            wallSeconds: 40,
            stage4Overhead: 0.03
        )

        let decision = TuringQwenNativePhase5PromotionPolicy().evaluate(
            control: control,
            candidate: candidate
        )

        #expect(decision.isEligibleForExplicitPromotion)
        #expect(decision.automaticallyChangesShippingTopology == false)
        guard case .eligibleForExplicitPromotion(let evidence) = decision else {
            Issue.record("Expected explicit-promotion eligibility evidence.")
            return
        }
        #expect(evidence.candidateMode == .twoLanePerStream)
        #expect(evidence.firstPCMP95DeltaSeconds < 0)
        #expect(evidence.firstCompletedSegmentP95DeltaSeconds < 0)
        #expect(evidence.aggregateAudioSecondsPerWallSecondDelta > 0)
        #expect(evidence.stage4OverheadDeltaSecondsPerAudioSecond < 0)
    }

    @Test
    func inactiveOrMoreExpensiveStage4AlwaysRetainsShippingTopology()
        throws
    {
        let control = try makeMetrics(
            mode: .currentTwoLaneDefaultStreamControl,
            stage4Active: true,
            stage4Overhead: 0.03
        )
        let inactiveCandidate = try makeMetrics(
            mode: .singleLane,
            stage4Active: false,
            firstPCMP50: 0.4,
            firstPCMP95: 0.5,
            firstSegmentP50: 2,
            firstSegmentP95: 3,
            audioSeconds: 80,
            wallSeconds: 30,
            stage4Overhead: 0.01
        )
        let expensiveCandidate = try makeMetrics(
            mode: .singleLane,
            firstPCMP50: 0.4,
            firstPCMP95: 0.5,
            firstSegmentP50: 2,
            firstSegmentP95: 3,
            audioSeconds: 80,
            wallSeconds: 30,
            stage4Overhead: 0.031
        )

        let inactiveDecision = TuringQwenNativePhase5PromotionPolicy()
            .evaluate(control: control, candidate: inactiveCandidate)
        let expensiveDecision = TuringQwenNativePhase5PromotionPolicy()
            .evaluate(control: control, candidate: expensiveCandidate)

        #expect(
            reasons(in: inactiveDecision).contains(.stage4StreamingInactive)
        )
        #expect(
            reasons(in: expensiveDecision).contains(
                .stage4OverheadRegression
            )
        )
        #expect(inactiveDecision.automaticallyChangesShippingTopology == false)
        #expect(expensiveDecision.automaticallyChangesShippingTopology == false)
    }

    @Test
    func qualityUnderrunAndOrderingGatesAreAbsolute() throws {
        let control = try makeMetrics(
            mode: .currentTwoLaneDefaultStreamControl
        )
        let candidate = try makeMetrics(
            mode: .singleLane,
            firstPCMP50: 0.5,
            firstPCMP95: 0.6,
            firstSegmentP50: 2,
            firstSegmentP95: 3,
            audioSeconds: 80,
            wallSeconds: 30,
            stage4Overhead: 0.01,
            underruns: 1,
            missing: 1,
            duplicates: 1,
            reordered: 1,
            speechQualityPassed: false,
            cloneIdentityPassed: false
        )

        let decision = TuringQwenNativePhase5PromotionPolicy().evaluate(
            control: control,
            candidate: candidate
        )
        let failures = reasons(in: decision)

        #expect(failures.contains(.speechQualityRegression))
        #expect(failures.contains(.cloneIdentityRegression))
        #expect(failures.contains(.playbackUnderrun))
        #expect(failures.contains(.missingSpeech))
        #expect(failures.contains(.duplicateSpeech))
        #expect(failures.contains(.reorderedSpeech))
        #expect(decision.isEligibleForExplicitPromotion == false)
    }

    @Test
    func unsupportedMicrobatchAndUnmeasuredWinCannotBePromoted() throws {
        let control = try makeMetrics(
            mode: .currentTwoLaneDefaultStreamControl
        )
        let microbatch = try makeMetrics(mode: .microbatch2)
        let equalSingleLane = try makeMetrics(mode: .singleLane)

        let policy = TuringQwenNativePhase5PromotionPolicy()
        let microbatchDecision = policy.evaluate(
            control: control,
            candidate: microbatch
        )
        let equalDecision = policy.evaluate(
            control: control,
            candidate: equalSingleLane
        )

        #expect(
            reasons(in: microbatchDecision).contains(
                .unsupportedCandidateMode
            )
        )
        #expect(reasons(in: equalDecision).contains(.noMeasuredBenefit))
    }

    @Test
    func mismatchedCorpusOrRunCountsCannotBeCompared() throws {
        let control = try makeMetrics(
            mode: .currentTwoLaneDefaultStreamControl,
            completedRuns: 10
        )
        let candidate = try makeMetrics(
            mode: .twoLanePerStream,
            context: makeContext(suffix: "-different"),
            completedRuns: 9,
            firstPCMP50: 0.5,
            firstPCMP95: 0.6
        )

        let decision = TuringQwenNativePhase5PromotionPolicy().evaluate(
            control: control,
            candidate: candidate
        )
        let failures = reasons(in: decision)
        #expect(failures.contains(.incomparableEvidence))
        #expect(failures.contains(.unequalRunCounts))
    }

    private func makeContext(
        suffix: String = ""
    ) throws -> TuringQwenNativePhase5BenchmarkContext {
        try .init(
            corpusDigest: "corpus-v1\(suffix)",
            modelIdentifier: "qwen3-tts-1.7b-base-4bit",
            deviceIdentifier: "vision-pro",
            buildConfiguration: "Release",
            generationSettingsDigest: "settings-v1",
            stage4ConfigurationDigest: "stage4-v1"
        )
    }

    private func makeMetrics(
        mode: TuringQwenNativePhase5QualificationMode,
        context: TuringQwenNativePhase5BenchmarkContext? = nil,
        completedRuns: Int = 10,
        stage4Active: Bool = true,
        firstPCMP50: Double = 0.8,
        firstPCMP95: Double = 1.0,
        firstSegmentP50: Double = 4.0,
        firstSegmentP95: Double = 5.0,
        audioSeconds: Double = 60,
        wallSeconds: Double = 40,
        stage4Overhead: Double = 0.03,
        underruns: Int = 0,
        missing: Int = 0,
        duplicates: Int = 0,
        reordered: Int = 0,
        speechQualityPassed: Bool = true,
        cloneIdentityPassed: Bool = true
    ) throws -> TuringQwenNativePhase5QualificationMetrics {
        try .init(
            mode: mode,
            context: context ?? makeContext(),
            completedRunCount: completedRuns,
            stage4StreamingActive: stage4Active,
            firstPCMSecondsP50: firstPCMP50,
            firstPCMSecondsP95: firstPCMP95,
            firstCompletedSegmentSecondsP50: firstSegmentP50,
            firstCompletedSegmentSecondsP95: firstSegmentP95,
            aggregateGeneratedAudioSeconds: audioSeconds,
            aggregateGenerationWallSeconds: wallSeconds,
            stage4OverheadSecondsPerAudioSecond: stage4Overhead,
            underrunCount: underruns,
            missingSpeechCount: missing,
            duplicateSpeechCount: duplicates,
            reorderedSpeechCount: reordered,
            speechQualityPassed: speechQualityPassed,
            cloneIdentityPassed: cloneIdentityPassed
        )
    }

    private func reasons(
        in decision: TuringQwenNativePhase5RetentionDecision
    ) -> [TuringQwenNativePhase5RetentionReason] {
        switch decision {
        case .retainCurrentShippingTopology(let reasons):
            reasons
        case .eligibleForExplicitPromotion:
            []
        }
    }
}
