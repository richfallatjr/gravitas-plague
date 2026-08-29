import Foundation

nonisolated struct TuringPocketSphinxRuntimeLipSyncConfiguration:
    Sendable,
    Equatable
{
    let permitForcedText: Bool
    let permitAllPhoneFallback: Bool

    static let production = Self(
        permitForcedText: true,
        permitAllPhoneFallback: true
    )
}

nonisolated final class TuringPocketSphinxRuntimeLipSyncGenerator:
    TuringRuntimeLipSyncManifestGenerating,
    @unchecked Sendable
{
    let generatorID = "pocketsphinx-forced-align"
    let generatorVersion = "5.1.1"

    private let configuration: TuringPocketSphinxRuntimeLipSyncConfiguration
    private let engineOwner: TuringRuntimeLipSyncEngineOwner
    private let pcmPreprocessor = TuringRuntimeLipSyncPCMPreprocessor()
    private let textNormalizer = TuringRuntimeLipSyncTextNormalizer()
    private let phoneTimelineMapper = TuringRuntimeLipSyncPhoneTimelineMapper()
    private let boundaryRefiner = TuringRuntimeLipSyncBoundaryRefiner()

    init(
        resourceLocator: TuringRuntimeLipSyncResourceLocator,
        configuration: TuringPocketSphinxRuntimeLipSyncConfiguration = .production
    ) {
        self.configuration = configuration
        engineOwner = TuringRuntimeLipSyncEngineOwner(
            resourceLocator: resourceLocator
        )
    }

    func generateManifest(
        for segment: TuringRuntimeLipSyncSegment,
        deadline: ContinuousClock.Instant,
        cancellationToken: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringRuntimeLipSyncManifest {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let totalStart = ContinuousClock.now
        try Self.check(cancellationToken, deadline)
        let input = try TuringRuntimeLipSyncInput(
            identity: segment.segmentIdentity,
            exactSourceText: segment.sourceText ?? "",
            interleavedPCM: segment.processedAudio,
            sampleRate: segment.sampleRate,
            channelCount: segment.channelCount,
            queuedAt: totalStart
        )
        let preprocessingStart = ContinuousClock.now
        let preparedPCM = try pcmPreprocessor.prepare(
            input: input,
            cancellation: cancellationToken
        )
        let preprocessingNanoseconds = Self.nanoseconds(
            preprocessingStart.duration(to: .now)
        )
        try Self.check(cancellationToken, deadline)
        let lease = try engineOwner.lease(for: input.identity.runID)
        let normalized: TuringRuntimeLipSyncNormalizedText
        if input.exactSourceText.isEmpty {
            normalized = .init(
                authoritativeTextSHA256: input.identity.sourceTextSHA256,
                normalizedAlignmentText: "",
                normalizedWords: [],
                unresolvedWords: [],
                transformationCodes: ["missingExactText"]
            )
        } else {
            normalized = try textNormalizer.normalize(
                exactText: input.exactSourceText,
                wordKnown: { lease.engine.hasWord($0) }
            )
        }

        var forcedFailure: String?
        var alignment: TuringPocketSphinxAlignmentResult?
        if configuration.permitForcedText,
           !normalized.normalizedWords.isEmpty,
           normalized.unresolvedWords.isEmpty {
            do {
                alignment = try lease.engine.forceAlign(
                    words: normalized.normalizedAlignmentText,
                    pcm16: preparedPCM.monoPCM16,
                    deadline: deadline,
                    cancellation: cancellationToken
                )
            } catch TuringRuntimeLipSyncFailure.cancelled { throw TuringRuntimeLipSyncFailure.cancelled }
            catch TuringRuntimeLipSyncFailure.deadlineExceeded { throw TuringRuntimeLipSyncFailure.deadlineExceeded }
            catch { forcedFailure = String(describing: error) }
        } else if !normalized.unresolvedWords.isEmpty {
            forcedFailure = "unresolvedWords"
        } else {
            forcedFailure = "exactTextMissing"
        }
        if alignment == nil, configuration.permitAllPhoneFallback {
            alignment = try lease.engine.allPhoneAlign(
                pcm16: preparedPCM.monoPCM16,
                deadline: deadline,
                cancellation: cancellationToken
            )
        }
        guard let alignment else {
            throw TuringRuntimeLipSyncFailure.allPhoneAlignmentFailed(
                forcedFailure ?? "No native alignment result."
            )
        }
        let mappingStart = ContinuousClock.now
        let sourcePhones = try phoneTimelineMapper.map(
            alignment: alignment,
            sourceSampleRate: input.sampleRate,
            sourceSampleCount: input.sampleCountPerChannel
        )
        let refined = try boundaryRefiner.refine(
            phones: sourcePhones,
            finalPCM: input.interleavedPCM,
            sampleRate: input.sampleRate,
            channelCount: input.channelCount,
            cancellation: cancellationToken,
            deadline: deadline
        )
        let mappingNanoseconds = Self.nanoseconds(mappingStart.duration(to: .now))
        let timing = TuringRuntimeLipSyncManifestTiming(
            engineColdStartNanoseconds: lease.coldStartNanoseconds,
            queueDelayNanoseconds: 0,
            preprocessingNanoseconds: preprocessingNanoseconds,
            firstPassNanoseconds: alignment.firstPassNanoseconds,
            secondPassNanoseconds: alignment.secondPassNanoseconds,
            mappingNanoseconds: mappingNanoseconds,
            totalAnalysisNanoseconds: Self.nanoseconds(totalStart.duration(to: .now)),
            fallbackReason: forcedFailure
        )
        let manifest = try TuringRuntimeLipSyncManifestBuilder(
            generatorID: generatorID,
            generatorVersion: generatorVersion
        ).build(
            input: input,
            sourcePCM: preparedPCM,
            normalizedText: normalized,
            refinedPhones: refined,
            quality: alignment.quality,
            timing: timing
        )
        let failures = TuringRuntimeLipSyncManifestValidator.failures(
            manifest,
            against: input,
            sourcePCM_SHA256: preparedPCM.sourcePCM_SHA256
        )
        guard failures.isEmpty else {
            throw TuringRuntimeLipSyncFailure.invalidManifest(
                failures.joined(separator: ",")
            )
        }
        return manifest
    }

    func unload(reason: String) {
        engineOwner.unload(reason: reason)
    }

    private static func check(
        _ cancellation: TuringGeneratedSpeechAnalysisCancellationToken,
        _ deadline: ContinuousClock.Instant
    ) throws {
        if cancellation.isCancelled { throw TuringRuntimeLipSyncFailure.cancelled }
        if ContinuousClock.now >= deadline { throw TuringRuntimeLipSyncFailure.deadlineExceeded }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !product.overflow else { return .max }
        let sum = product.partialValue.addingReportingOverflow(nanos)
        return sum.overflow ? .max : sum.partialValue
    }
}
