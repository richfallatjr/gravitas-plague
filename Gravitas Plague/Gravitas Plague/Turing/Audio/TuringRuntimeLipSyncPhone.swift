import Foundation

nonisolated struct TuringPocketSphinxPhoneSegment: Sendable, Equatable {
    let phone: String
    let startFrame: Int
    let durationFrames: Int
    let acousticScore: Int
}

nonisolated struct TuringPocketSphinxAlignmentResult: Sendable, Equatable {
    let quality: TuringRuntimeLipSyncQuality
    let alignmentFrameRate: Int
    let searchedAudioFrameCount: Int
    let segments: [TuringPocketSphinxPhoneSegment]
    let firstPassNanoseconds: UInt64?
    let secondPassNanoseconds: UInt64?
}

nonisolated struct TuringRuntimeLipSyncSourcePhoneSpan: Sendable, Equatable {
    let phone: String
    let pose: TuringGeneratedMouthPose
    let startSample: Int
    let endSampleExclusive: Int
    let unknownAllPhoneLabel: Bool

    var sampleCount: Int { endSampleExclusive - startSample }
}

nonisolated struct TuringRuntimeLipSyncPhoneTimelineMapper: Sendable {
    func map(
        alignment: TuringPocketSphinxAlignmentResult,
        sourceSampleRate: Int,
        sourceSampleCount: Int
    ) throws -> [TuringRuntimeLipSyncSourcePhoneSpan] {
        guard alignment.alignmentFrameRate > 0,
              sourceSampleRate > 0,
              sourceSampleCount > 0,
              !alignment.segments.isEmpty else {
            throw TuringRuntimeLipSyncFailure.invalidManifest(
                "Native phone alignment timeline is invalid."
            )
        }
        var spans: [TuringRuntimeLipSyncSourcePhoneSpan] = []
        for segment in alignment.segments {
            guard segment.startFrame >= 0, segment.durationFrames > 0 else { continue }
            let start = try Self.floorScale(
                segment.startFrame,
                multiplier: sourceSampleRate,
                divisor: alignment.alignmentFrameRate
            )
            let endFrame = segment.startFrame.addingReportingOverflow(
                segment.durationFrames
            )
            guard !endFrame.overflow else {
                throw TuringRuntimeLipSyncFailure.invalidManifest(
                    "Native phone frame range overflowed."
                )
            }
            let end = min(
                sourceSampleCount,
                try Self.ceilScale(
                    endFrame.partialValue,
                    multiplier: sourceSampleRate,
                    divisor: alignment.alignmentFrameRate
                )
            )
            guard start < end, start < sourceSampleCount else { continue }
            let normalized = Self.normalizedPhone(segment.phone)
            if normalized == "AW" || normalized == "OY" {
                let split = start + max(1, (end - start) * 55 / 100)
                let first: TuringGeneratedMouthPose = normalized == "AW" ? .wide : .round
                let second: TuringGeneratedMouthPose = normalized == "AW" ? .round : .wide
                spans.append(.init(
                    phone: normalized,
                    pose: first,
                    startSample: start,
                    endSampleExclusive: min(split, end),
                    unknownAllPhoneLabel: false
                ))
                if split < end {
                    spans.append(.init(
                        phone: normalized,
                        pose: second,
                        startSample: split,
                        endSampleExclusive: end,
                        unknownAllPhoneLabel: false
                    ))
                }
                continue
            }
            let mapping = Self.pose(
                for: normalized,
                allPhone: alignment.quality == .allPhoneFallback
            )
            guard let mapping else {
                throw TuringRuntimeLipSyncFailure.forcedAlignmentFailed(
                    "Forced alignment returned an unsupported phone label."
                )
            }
            spans.append(.init(
                phone: normalized,
                pose: mapping.pose,
                startSample: start,
                endSampleExclusive: end,
                unknownAllPhoneLabel: mapping.unknown
            ))
        }
        guard !spans.isEmpty else {
            throw TuringRuntimeLipSyncFailure.invalidManifest(
                "Phone alignment mapped to an empty source timeline."
            )
        }
        return spans.sorted {
            ($0.startSample, $0.endSampleExclusive) <
                ($1.startSample, $1.endSampleExclusive)
        }
    }

    static func normalizedPhone(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while value.last?.isNumber == true { value.removeLast() }
        return value
    }

    static func pose(
        for phone: String,
        allPhone: Bool
    ) -> (pose: TuringGeneratedMouthPose, unknown: Bool)? {
        if ["SIL", "<SIL>", "<EPS>", "+SPN+", "+NSN+", "+BR+"].contains(phone) {
            return (.rest, false)
        }
        if ["P", "B", "M", "T", "D", "K", "G", "N", "NG", "L", "R", "Y", "HH"].contains(phone) {
            return (.small, false)
        }
        if ["AA", "AE", "AH", "EH", "ER", "IH", "IY", "AY", "EY"].contains(phone) {
            return (.wide, false)
        }
        if ["W", "AO", "OW", "UH", "UW"].contains(phone) {
            return (.round, false)
        }
        if ["F", "V", "S", "Z", "SH", "ZH", "CH", "JH", "TH", "DH"].contains(phone) {
            return (.teeth, false)
        }
        return allPhone ? (.wide, true) : nil
    }

    private static func floorScale(
        _ value: Int,
        multiplier: Int,
        divisor: Int
    ) throws -> Int {
        let product = value.multipliedReportingOverflow(by: multiplier)
        guard !product.overflow else {
            throw TuringRuntimeLipSyncFailure.invalidManifest("Phone time overflowed.")
        }
        return product.partialValue / divisor
    }

    private static func ceilScale(
        _ value: Int,
        multiplier: Int,
        divisor: Int
    ) throws -> Int {
        let product = value.multipliedReportingOverflow(by: multiplier)
        guard !product.overflow else {
            throw TuringRuntimeLipSyncFailure.invalidManifest("Phone time overflowed.")
        }
        let numerator = product.partialValue.addingReportingOverflow(divisor - 1)
        guard !numerator.overflow else {
            throw TuringRuntimeLipSyncFailure.invalidManifest("Phone time overflowed.")
        }
        return numerator.partialValue / divisor
    }
}
