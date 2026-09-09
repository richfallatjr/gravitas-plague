import Foundation

/// Phase 5 is a qualification matrix, not a production-topology switch.
///
/// The current two-lane topology is included explicitly because the roadmap's
/// historical three-lane description no longer matches the shipping runtime.
public enum TuringQwenNativePhase5QualificationMode:
    String,
    CaseIterable,
    Codable,
    Sendable
{
    case currentTwoLaneDefaultStreamControl
    case singleLane
    case threeLaneDefaultStream
    case twoLanePerStream
    case threeLanePerStream
    case microbatch2

    public var requestedLaneCount: Int {
        switch self {
        case .singleLane:
            1
        case .currentTwoLaneDefaultStreamControl,
             .twoLanePerStream,
             .microbatch2:
            2
        case .threeLaneDefaultStream,
             .threeLanePerStream:
            3
        }
    }

    public var executionStrategy:
        TuringQwenNativePhase5ExecutionStrategy
    {
        switch self {
        case .currentTwoLaneDefaultStreamControl,
             .singleLane,
             .threeLaneDefaultStream:
            .defaultGPUStream
        case .twoLanePerStream,
             .threeLanePerStream:
            .perTaskGPUStream
        case .microbatch2:
            .microbatch
        }
    }

    public var requiredCapabilities: [TuringQwenNativePhase5Capability] {
        switch executionStrategy {
        case .defaultGPUStream:
            [.defaultGPUStream]
        case .perTaskGPUStream:
            [.perTaskGPUStreams]
        case .microbatch:
            [.batchedKVCacheAndSampling]
        }
    }

    public var isCurrentShippingControl: Bool {
        self == .currentTwoLaneDefaultStreamControl
    }
}

public enum TuringQwenNativePhase5ExecutionStrategy:
    String,
    Codable,
    Sendable
{
    case defaultGPUStream
    case perTaskGPUStream
    case microbatch
}

public enum TuringQwenNativePhase5Capability:
    String,
    CaseIterable,
    Codable,
    Sendable
{
    case defaultGPUStream
    case perTaskGPUStreams
    case batchedKVCacheAndSampling
}

public enum TuringQwenNativePhase5CapabilityAvailability:
    String,
    Codable,
    Sendable
{
    case supported
    case unsupported
}

public struct TuringQwenNativePhase5CapabilityAssessment:
    Codable,
    Equatable,
    Sendable
{
    public let capability: TuringQwenNativePhase5Capability
    public let availability: TuringQwenNativePhase5CapabilityAvailability
    public let evidence: String

    public init(
        capability: TuringQwenNativePhase5Capability,
        availability: TuringQwenNativePhase5CapabilityAvailability,
        evidence: String
    ) {
        self.capability = capability
        self.availability = availability
        self.evidence = evidence
    }
}

public struct TuringQwenNativePhase5ModeCapability:
    Codable,
    Equatable,
    Sendable
{
    public let mode: TuringQwenNativePhase5QualificationMode
    public let requiredCapabilities: [TuringQwenNativePhase5Capability]
    public let missingCapabilities: [TuringQwenNativePhase5Capability]

    public var isSupported: Bool {
        missingCapabilities.isEmpty
    }
}

/// A source-audited view of the MLX Swift API installed in this repository.
///
/// `Stream.withNewDefaultStream(device:_:)` supports task-scoped GPU streams.
/// The native Qwen engine does not yet have a batched cache/position/sampling
/// contract, so exposing `microbatch2` as executable would be a false claim.
public struct TuringQwenNativePhase5CapabilitySet:
    Codable,
    Equatable,
    Sendable
{
    public let assessments: [TuringQwenNativePhase5CapabilityAssessment]

    public static let installedMLXSwift = Self(
        assessments: [
            .init(
                capability: .defaultGPUStream,
                availability: .supported,
                evidence: "The installed MLX Swift runtime exposes the default GPU stream."
            ),
            .init(
                capability: .perTaskGPUStreams,
                availability: .supported,
                evidence: "The installed MLX Swift runtime exposes Stream.withNewDefaultStream(device:_:) for synchronous and asynchronous task scopes."
            ),
            .init(
                capability: .batchedKVCacheAndSampling,
                availability: .unsupported,
                evidence: "The current native Qwen engine has no batched KV-cache, position-state, or sampling contract; microbatch2 remains unavailable until all three are implemented and qualified."
            )
        ]
    )

    public init(
        assessments: [TuringQwenNativePhase5CapabilityAssessment]
    ) {
        self.assessments = assessments
    }

    public func assessment(
        for capability: TuringQwenNativePhase5Capability
    ) -> TuringQwenNativePhase5CapabilityAssessment? {
        assessments.first { $0.capability == capability }
    }

    public func classify(
        _ mode: TuringQwenNativePhase5QualificationMode
    ) -> TuringQwenNativePhase5ModeCapability {
        let missing = mode.requiredCapabilities.filter { capability in
            assessment(for: capability)?.availability != .supported
        }
        return .init(
            mode: mode,
            requiredCapabilities: mode.requiredCapabilities,
            missingCapabilities: missing
        )
    }
}

/// Values that must be identical before two Phase 5 measurements are compared.
public struct TuringQwenNativePhase5BenchmarkContext:
    Codable,
    Equatable,
    Sendable
{
    public let corpusDigest: String
    public let modelIdentifier: String
    public let deviceIdentifier: String
    public let buildConfiguration: String
    public let generationSettingsDigest: String
    public let stage4ConfigurationDigest: String

    public init(
        corpusDigest: String,
        modelIdentifier: String,
        deviceIdentifier: String,
        buildConfiguration: String,
        generationSettingsDigest: String,
        stage4ConfigurationDigest: String
    ) throws {
        let values = [
            corpusDigest,
            modelIdentifier,
            deviceIdentifier,
            buildConfiguration,
            generationSettingsDigest,
            stage4ConfigurationDigest
        ]
        guard values.allSatisfy({ !$0.isEmpty }) else {
            throw TuringQwenNativeError.invalidConfig(
                "Phase 5 benchmark context fields must be nonempty."
            )
        }
        self.corpusDigest = corpusDigest
        self.modelIdentifier = modelIdentifier
        self.deviceIdentifier = deviceIdentifier
        self.buildConfiguration = buildConfiguration
        self.generationSettingsDigest = generationSettingsDigest
        self.stage4ConfigurationDigest = stage4ConfigurationDigest
    }
}

/// Machine-encodable Phase 5 evidence. Latency is centered on the first PCM and
/// first completed segment because Plague values the next audible response over
/// speculative aggregate concurrency. Aggregate throughput is retained so a
/// topology cannot hide a total-capacity regression.
public struct TuringQwenNativePhase5QualificationMetrics:
    Codable,
    Equatable,
    Sendable
{
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let mode: TuringQwenNativePhase5QualificationMode
    public let context: TuringQwenNativePhase5BenchmarkContext
    public let completedRunCount: Int
    public let stage4StreamingActive: Bool
    public let firstPCMSecondsP50: Double
    public let firstPCMSecondsP95: Double
    public let firstCompletedSegmentSecondsP50: Double
    public let firstCompletedSegmentSecondsP95: Double
    public let aggregateGeneratedAudioSeconds: Double
    public let aggregateGenerationWallSeconds: Double
    public let stage4OverheadSecondsPerAudioSecond: Double
    public let underrunCount: Int
    public let missingSpeechCount: Int
    public let duplicateSpeechCount: Int
    public let reorderedSpeechCount: Int
    public let speechQualityPassed: Bool
    public let cloneIdentityPassed: Bool

    public init(
        mode: TuringQwenNativePhase5QualificationMode,
        context: TuringQwenNativePhase5BenchmarkContext,
        completedRunCount: Int,
        stage4StreamingActive: Bool,
        firstPCMSecondsP50: Double,
        firstPCMSecondsP95: Double,
        firstCompletedSegmentSecondsP50: Double,
        firstCompletedSegmentSecondsP95: Double,
        aggregateGeneratedAudioSeconds: Double,
        aggregateGenerationWallSeconds: Double,
        stage4OverheadSecondsPerAudioSecond: Double,
        underrunCount: Int,
        missingSpeechCount: Int,
        duplicateSpeechCount: Int,
        reorderedSpeechCount: Int,
        speechQualityPassed: Bool,
        cloneIdentityPassed: Bool
    ) throws {
        let finiteNonnegativeValues = [
            firstPCMSecondsP50,
            firstPCMSecondsP95,
            firstCompletedSegmentSecondsP50,
            firstCompletedSegmentSecondsP95,
            stage4OverheadSecondsPerAudioSecond
        ]
        guard completedRunCount > 0,
              finiteNonnegativeValues.allSatisfy({ $0.isFinite && $0 >= 0 }),
              firstPCMSecondsP50 <= firstPCMSecondsP95,
              firstCompletedSegmentSecondsP50 <=
                firstCompletedSegmentSecondsP95,
              aggregateGeneratedAudioSeconds.isFinite,
              aggregateGeneratedAudioSeconds > 0,
              aggregateGenerationWallSeconds.isFinite,
              aggregateGenerationWallSeconds > 0,
              underrunCount >= 0,
              missingSpeechCount >= 0,
              duplicateSpeechCount >= 0,
              reorderedSpeechCount >= 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Phase 5 qualification metrics are incomplete or invalid."
            )
        }

        self.schemaVersion = Self.schemaVersion
        self.mode = mode
        self.context = context
        self.completedRunCount = completedRunCount
        self.stage4StreamingActive = stage4StreamingActive
        self.firstPCMSecondsP50 = firstPCMSecondsP50
        self.firstPCMSecondsP95 = firstPCMSecondsP95
        self.firstCompletedSegmentSecondsP50 =
            firstCompletedSegmentSecondsP50
        self.firstCompletedSegmentSecondsP95 =
            firstCompletedSegmentSecondsP95
        self.aggregateGeneratedAudioSeconds = aggregateGeneratedAudioSeconds
        self.aggregateGenerationWallSeconds = aggregateGenerationWallSeconds
        self.stage4OverheadSecondsPerAudioSecond =
            stage4OverheadSecondsPerAudioSecond
        self.underrunCount = underrunCount
        self.missingSpeechCount = missingSpeechCount
        self.duplicateSpeechCount = duplicateSpeechCount
        self.reorderedSpeechCount = reorderedSpeechCount
        self.speechQualityPassed = speechQualityPassed
        self.cloneIdentityPassed = cloneIdentityPassed
    }

    public var aggregateAudioSecondsPerWallSecond: Double {
        aggregateGeneratedAudioSeconds / aggregateGenerationWallSeconds
    }
}

public enum TuringQwenNativePhase5RetentionReason:
    String,
    Codable,
    Sendable
{
    case controlIsNotCurrentShippingTopology
    case candidateIsCurrentShippingControl
    case unsupportedCandidateMode
    case incomparableEvidence
    case unequalRunCounts
    case stage4StreamingInactive
    case stage4OverheadRegression
    case firstPCMRegression
    case firstCompletedSegmentRegression
    case aggregateThroughputRegression
    case speechQualityRegression
    case cloneIdentityRegression
    case playbackUnderrun
    case missingSpeech
    case duplicateSpeech
    case reorderedSpeech
    case noMeasuredBenefit
}

public struct TuringQwenNativePhase5PromotionEvidence:
    Codable,
    Equatable,
    Sendable
{
    public let candidateMode: TuringQwenNativePhase5QualificationMode
    public let firstPCMP95DeltaSeconds: Double
    public let firstCompletedSegmentP95DeltaSeconds: Double
    public let aggregateAudioSecondsPerWallSecondDelta: Double
    public let stage4OverheadDeltaSecondsPerAudioSecond: Double
}

public enum TuringQwenNativePhase5RetentionDecision:
    Equatable,
    Sendable
{
    case retainCurrentShippingTopology(
        reasons: [TuringQwenNativePhase5RetentionReason]
    )
    case eligibleForExplicitPromotion(
        evidence: TuringQwenNativePhase5PromotionEvidence
    )

    /// Phase 5 only reports eligibility. A caller must make a separate,
    /// deliberate production configuration change after reviewing the evidence.
    public var automaticallyChangesShippingTopology: Bool {
        false
    }

    public var isEligibleForExplicitPromotion: Bool {
        if case .eligibleForExplicitPromotion = self {
            true
        } else {
            false
        }
    }
}

/// Strict measured promotion policy. Timing tolerances default to zero so
/// "neutral-or-better" cannot silently become an accepted regression.
public struct TuringQwenNativePhase5PromotionPolicy: Sendable {
    public let timingToleranceSeconds: Double
    public let throughputTolerance: Double

    public init(
        timingToleranceSeconds: Double = 0,
        throughputTolerance: Double = 0
    ) {
        precondition(timingToleranceSeconds >= 0)
        precondition(throughputTolerance >= 0)
        self.timingToleranceSeconds = timingToleranceSeconds
        self.throughputTolerance = throughputTolerance
    }

    public func evaluate(
        control: TuringQwenNativePhase5QualificationMetrics,
        candidate: TuringQwenNativePhase5QualificationMetrics,
        capabilities: TuringQwenNativePhase5CapabilitySet =
            .installedMLXSwift
    ) -> TuringQwenNativePhase5RetentionDecision {
        var reasons: [TuringQwenNativePhase5RetentionReason] = []

        append(
            .controlIsNotCurrentShippingTopology,
            unless: control.mode.isCurrentShippingControl,
            to: &reasons
        )
        append(
            .candidateIsCurrentShippingControl,
            unless: !candidate.mode.isCurrentShippingControl,
            to: &reasons
        )
        append(
            .unsupportedCandidateMode,
            unless: capabilities.classify(candidate.mode).isSupported,
            to: &reasons
        )
        append(
            .incomparableEvidence,
            unless: control.context == candidate.context,
            to: &reasons
        )
        append(
            .unequalRunCounts,
            unless: control.completedRunCount == candidate.completedRunCount,
            to: &reasons
        )
        append(
            .stage4StreamingInactive,
            unless: control.stage4StreamingActive &&
                candidate.stage4StreamingActive,
            to: &reasons
        )
        append(
            .stage4OverheadRegression,
            unless: candidate.stage4OverheadSecondsPerAudioSecond <=
                control.stage4OverheadSecondsPerAudioSecond +
                timingToleranceSeconds,
            to: &reasons
        )
        append(
            .firstPCMRegression,
            unless: candidate.firstPCMSecondsP50 <=
                control.firstPCMSecondsP50 + timingToleranceSeconds &&
                candidate.firstPCMSecondsP95 <=
                control.firstPCMSecondsP95 + timingToleranceSeconds,
            to: &reasons
        )
        append(
            .firstCompletedSegmentRegression,
            unless: candidate.firstCompletedSegmentSecondsP50 <=
                control.firstCompletedSegmentSecondsP50 +
                timingToleranceSeconds &&
                candidate.firstCompletedSegmentSecondsP95 <=
                control.firstCompletedSegmentSecondsP95 +
                timingToleranceSeconds,
            to: &reasons
        )
        append(
            .aggregateThroughputRegression,
            unless: candidate.aggregateAudioSecondsPerWallSecond +
                throughputTolerance >=
                control.aggregateAudioSecondsPerWallSecond,
            to: &reasons
        )
        append(
            .speechQualityRegression,
            unless: candidate.speechQualityPassed,
            to: &reasons
        )
        append(
            .cloneIdentityRegression,
            unless: candidate.cloneIdentityPassed,
            to: &reasons
        )
        append(
            .playbackUnderrun,
            unless: candidate.underrunCount == 0,
            to: &reasons
        )
        append(
            .missingSpeech,
            unless: candidate.missingSpeechCount == 0,
            to: &reasons
        )
        append(
            .duplicateSpeech,
            unless: candidate.duplicateSpeechCount == 0,
            to: &reasons
        )
        append(
            .reorderedSpeech,
            unless: candidate.reorderedSpeechCount == 0,
            to: &reasons
        )

        let hasMeasuredBenefit =
            candidate.firstPCMSecondsP50 < control.firstPCMSecondsP50 ||
            candidate.firstPCMSecondsP95 < control.firstPCMSecondsP95 ||
            candidate.firstCompletedSegmentSecondsP50 <
                control.firstCompletedSegmentSecondsP50 ||
            candidate.firstCompletedSegmentSecondsP95 <
                control.firstCompletedSegmentSecondsP95 ||
            candidate.aggregateAudioSecondsPerWallSecond >
                control.aggregateAudioSecondsPerWallSecond ||
            candidate.stage4OverheadSecondsPerAudioSecond <
                control.stage4OverheadSecondsPerAudioSecond
        append(
            .noMeasuredBenefit,
            unless: hasMeasuredBenefit,
            to: &reasons
        )

        guard reasons.isEmpty else {
            return .retainCurrentShippingTopology(reasons: reasons)
        }

        return .eligibleForExplicitPromotion(
            evidence: .init(
                candidateMode: candidate.mode,
                firstPCMP95DeltaSeconds:
                    candidate.firstPCMSecondsP95 -
                    control.firstPCMSecondsP95,
                firstCompletedSegmentP95DeltaSeconds:
                    candidate.firstCompletedSegmentSecondsP95 -
                    control.firstCompletedSegmentSecondsP95,
                aggregateAudioSecondsPerWallSecondDelta:
                    candidate.aggregateAudioSecondsPerWallSecond -
                    control.aggregateAudioSecondsPerWallSecond,
                stage4OverheadDeltaSecondsPerAudioSecond:
                    candidate.stage4OverheadSecondsPerAudioSecond -
                    control.stage4OverheadSecondsPerAudioSecond
            )
        )
    }

    private func append(
        _ reason: TuringQwenNativePhase5RetentionReason,
        unless condition: Bool,
        to reasons: inout [TuringQwenNativePhase5RetentionReason]
    ) {
        if !condition {
            reasons.append(reason)
        }
    }
}
