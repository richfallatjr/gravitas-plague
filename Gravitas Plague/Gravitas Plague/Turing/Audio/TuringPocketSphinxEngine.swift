import Foundation
import TuringPocketSphinx

nonisolated final class TuringPocketSphinxEngine: @unchecked Sendable {
    let generatorID = "pocketsphinx-forced-align"
    let generatorVersion: String
    private var engine: OpaquePointer?

    init(resources: TuringRuntimeLipSyncResolvedResources) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var bridgeError = trl_error_t()
        let created = resources.acousticModelURL.path.withCString { acoustic in
            resources.dictionaryURL.path.withCString { dictionary in
                resources.allPhoneLanguageModelURL.path.withCString { allPhone in
                    trl_engine_create(acoustic, dictionary, allPhone, &bridgeError)
                }
            }
        }
        guard let created else {
            throw TuringRuntimeLipSyncFailure.engineLoadFailed(
                Self.message(bridgeError)
            )
        }
        engine = created
        generatorVersion = String(cString: trl_pocketsphinx_version())
        guard generatorVersion == resources.manifest.engineVersion else {
            trl_engine_destroy(created)
            engine = nil
            throw TuringRuntimeLipSyncFailure.engineLoadFailed(
                "Linked PocketSphinx version does not match the resource manifest."
            )
        }
        for entry in resources.pronunciationOverrides.entries {
            let word = entry.word.lowercased()
            let phones = entry.phones.map(
                TuringRuntimeLipSyncPhoneTimelineMapper.normalizedPhone
            )
            guard !word.isEmpty, !phones.isEmpty,
                  phones.allSatisfy({
                      TuringRuntimeLipSyncPhoneTimelineMapper.pose(
                        for: $0,
                        allPhone: false
                      ) != nil || $0 == "AW" || $0 == "OY"
                  }) else {
                throw TuringRuntimeLipSyncFailure.resourceInvalid(
                    "Pronunciation override contains an unsupported phone."
                )
            }
            var addError = trl_error_t()
            let status = word.withCString { wordPointer in
                phones.joined(separator: " ").withCString { phonePointer in
                    trl_engine_add_pronunciation(
                        created,
                        wordPointer,
                        phonePointer,
                        1,
                        &addError
                    )
                }
            }
            guard status == TRL_STATUS_OK else {
                throw TuringRuntimeLipSyncFailure.resourceInvalid(Self.message(addError))
            }
        }
    }

    deinit {
        if let engine { trl_engine_destroy(engine) }
    }

    func hasWord(_ word: String) -> Bool {
        guard let engine else { return false }
        return word.withCString { trl_engine_has_word(engine, $0) != 0 }
    }

    func forceAlign(
        words: String,
        pcm16: ContiguousArray<Int16>,
        deadline: ContinuousClock.Instant,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringPocketSphinxAlignmentResult {
        let start = ContinuousClock.now
        return try callAlignment(
            quality: .forcedTextPhones,
            pcm16: pcm16,
            deadline: deadline,
            cancellation: cancellation
        ) { engine, samples, count, cDeadline, callback, context, result, error in
            words.withCString {
                trl_engine_force_align(
                    engine,
                    $0,
                    samples,
                    count,
                    cDeadline,
                    callback,
                    context,
                    result,
                    error
                )
            }
        }.withPassTiming(firstPass: Self.nanoseconds(start.duration(to: .now)))
    }

    func allPhoneAlign(
        pcm16: ContiguousArray<Int16>,
        deadline: ContinuousClock.Instant,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringPocketSphinxAlignmentResult {
        let start = ContinuousClock.now
        return try callAlignment(
            quality: .allPhoneFallback,
            pcm16: pcm16,
            deadline: deadline,
            cancellation: cancellation
        ) { engine, samples, count, cDeadline, callback, context, result, error in
            trl_engine_allphone_align(
                engine,
                samples,
                count,
                cDeadline,
                callback,
                context,
                result,
                error
            )
        }.withPassTiming(secondPass: Self.nanoseconds(start.duration(to: .now)))
    }

    func unload() {
        if let engine { trl_engine_destroy(engine) }
        engine = nil
    }

    private typealias AlignmentCall = (
        OpaquePointer,
        UnsafePointer<Int16>,
        Int,
        UInt64,
        trl_should_cancel_fn?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<trl_alignment_result_t>,
        UnsafeMutablePointer<trl_error_t>
    ) -> trl_status_t

    private func callAlignment(
        quality: TuringRuntimeLipSyncQuality,
        pcm16: ContiguousArray<Int16>,
        deadline: ContinuousClock.Instant,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken,
        call: AlignmentCall
    ) throws -> TuringPocketSphinxAlignmentResult {
        guard let engine else {
            throw TuringRuntimeLipSyncFailure.engineLoadFailed("PocketSphinx engine is unloaded.")
        }
        let box = CancellationBox(cancellation)
        let context = Unmanaged.passUnretained(box).toOpaque()
        let callback: trl_should_cancel_fn = { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<CancellationBox>.fromOpaque(pointer)
                .takeUnretainedValue().token.isCancelled ? 1 : 0
        }
        let remaining = Self.nanoseconds(ContinuousClock.now.duration(to: deadline))
        let nativeNow = trl_monotonic_nanoseconds()
        let sum = nativeNow.addingReportingOverflow(remaining)
        let nativeDeadline = sum.overflow ? UInt64.max : sum.partialValue
        var nativeResult = trl_alignment_result_t()
        var bridgeError = trl_error_t()
        let status = pcm16.withUnsafeBufferPointer { samples in
            call(
                engine,
                samples.baseAddress!,
                samples.count,
                nativeDeadline,
                callback,
                context,
                &nativeResult,
                &bridgeError
            )
        }
        defer { trl_alignment_result_destroy(&nativeResult) }
        guard status == TRL_STATUS_OK else {
            switch status {
            case TRL_STATUS_CANCELLED:
                throw TuringRuntimeLipSyncFailure.cancelled
            case TRL_STATUS_DEADLINE_EXCEEDED:
                throw TuringRuntimeLipSyncFailure.deadlineExceeded
            case TRL_STATUS_OOV, TRL_STATUS_FIRST_PASS_FAILED,
                 TRL_STATUS_SECOND_PASS_FAILED, TRL_STATUS_ALIGNMENT_MISSING:
                throw TuringRuntimeLipSyncFailure.forcedAlignmentFailed(
                    Self.message(bridgeError)
                )
            default:
                throw quality == .allPhoneFallback
                    ? TuringRuntimeLipSyncFailure.allPhoneAlignmentFailed(
                        Self.message(bridgeError)
                    )
                    : TuringRuntimeLipSyncFailure.forcedAlignmentFailed(
                        Self.message(bridgeError)
                    )
            }
        }
        guard let nativeSegments = nativeResult.segments,
              nativeResult.segment_count > 0 else {
            throw TuringRuntimeLipSyncFailure.invalidManifest(
                "PocketSphinx returned an empty phone list."
            )
        }
        var segments: [TuringPocketSphinxPhoneSegment] = []
        segments.reserveCapacity(nativeResult.segment_count)
        for index in 0..<nativeResult.segment_count {
            var native = nativeSegments[index]
            let phone = withUnsafePointer(to: &native.phone) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) {
                    String(cString: $0)
                }
            }
            segments.append(.init(
                phone: phone,
                startFrame: Int(native.start_frame),
                durationFrames: Int(native.duration_frames),
                acousticScore: Int(native.acoustic_score)
            ))
        }
        return .init(
            quality: quality,
            alignmentFrameRate: Int(nativeResult.alignment_frame_rate),
            searchedAudioFrameCount: Int(nativeResult.searched_audio_frame_count),
            segments: segments,
            firstPassNanoseconds: nil,
            secondPassNanoseconds: nil
        )
    }

    private final class CancellationBox {
        let token: TuringGeneratedSpeechAnalysisCancellationToken
        init(_ token: TuringGeneratedSpeechAnalysisCancellationToken) { self.token = token }
    }

    private static func message(_ error: trl_error_t) -> String {
        var copy = error
        return withUnsafePointer(to: &copy.message) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
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

private extension TuringPocketSphinxAlignmentResult {
    func withPassTiming(
        firstPass: UInt64? = nil,
        secondPass: UInt64? = nil
    ) -> Self {
        .init(
            quality: quality,
            alignmentFrameRate: alignmentFrameRate,
            searchedAudioFrameCount: searchedAudioFrameCount,
            segments: segments,
            firstPassNanoseconds: firstPass ?? firstPassNanoseconds,
            secondPassNanoseconds: secondPass ?? secondPassNanoseconds
        )
    }
}
