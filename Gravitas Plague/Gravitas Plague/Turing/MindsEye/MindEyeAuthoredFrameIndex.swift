import Foundation

nonisolated struct MindEyeAuthoredFrameIndex:
    Codable,
    Sendable,
    Equatable
{
    struct Entry: Codable, Sendable, Equatable {
        struct PoseFrameCounts: Codable, Sendable, Equatable {
            let rest: Int
            let small: Int
            let wide: Int
            let round: Int
            let teeth: Int

            var total: Int {
                rest + small + wide + round + teeth
            }

            static func + (
                lhs: Self,
                rhs: Self
            ) -> Self {
                Self(
                    rest: lhs.rest + rhs.rest,
                    small: lhs.small + rhs.small,
                    wide: lhs.wide + rhs.wide,
                    round: lhs.round + rhs.round,
                    teeth: lhs.teeth + rhs.teeth
                )
            }

            static let zero = Self(
                rest: 0,
                small: 0,
                wide: 0,
                round: 0,
                teeth: 0
            )
        }

        let prID: String
        let speakerCharacterID: TuringConversationCharacterID
        let interactionSurface: StoryInteractionSurfaceID
        let manifestResourcePath: String
        let manifestSHA256: String
        let descriptorSHA256: String
        let audioSHA256: String
        let transcriptSHA256: String
        let sampleCount: Int
        let frameCount: Int
        let durationSeconds: Double
        let poseFrameCounts: PoseFrameCounts
        let speechFrameCount: Int
        let fallbackFrameCount: Int
        let manualOverrideFrameCount: Int
        let warningCount: Int
    }

    struct Summary: Codable, Sendable, Equatable {
        let manifestCount: Int
        let speakerManifestCounts: [String: Int]
        let surfaceManifestCounts: [String: Int]
        let totalSampleCount: Int
        let totalFrameCount: Int
        let totalDurationSeconds: Double
        let aggregatePoseFrameCounts: Entry.PoseFrameCounts
        let totalSpeechFrameCount: Int
        let totalFallbackFrameCount: Int
        let totalManualOverrideFrameCount: Int
        let totalWarningCount: Int
        let manifestBytes: Int
    }

    let schemaVersion: Int
    let setVersion: String
    let compilerVersion: String
    let expectedManifestCount: Int
    let manifestSetSHA256: String
    let registrySHA256: String
    let toolchainLockSHA256: String
    let compilerConfigSHA256: String
    let phonemePoseMapSHA256: String
    let pronunciationOverridesSHA256: String
    let entries: [Entry]
    let summary: Summary
}

nonisolated enum MindEyeAuthoredFrameIndexValidator {
    private static let expectedSpeakers = [
        "big_mike": 10,
        "rich": 15,
        "broadcaster": 5,
        "cateye81": 5,
        "dad": 2,
    ]
    private static let expectedSurfaces: Set<String> = [
        "walkie", "dadFrame", "crankRadio", "hamReceiver",
    ]

    static func validate(
        _ index: MindEyeAuthoredFrameIndex
    ) -> [MindEyeFailure] {
        var failures: [MindEyeFailure] = []

        func append(_ code: MindEyeFailureCode, _ message: String) {
            failures.append(MindEyeFailure(
                code: code,
                characterID: nil,
                vignetteID: nil,
                resourcePath: "Turing/MindsEye/AudioFrames/index.json",
                message: message
            ))
        }

        guard index.schemaVersion == 1,
              index.setVersion == "mind-eye-authored-frame-set/1",
              index.expectedManifestCount == 37 else {
            append(.authoredFrameIndexUnsupported, "Unsupported authored-frame index schema or set version.")
            return failures
        }
        guard index.entries.count == 37,
              index.summary.manifestCount == 37 else {
            append(.authoredFrameIndexInvalid, "The authored-frame index must contain exactly 37 entries.")
            return failures
        }
        let hashes = [
            index.manifestSetSHA256,
            index.registrySHA256,
            index.toolchainLockSHA256,
            index.compilerConfigSHA256,
            index.phonemePoseMapSHA256,
            index.pronunciationOverridesSHA256,
        ]
        if hashes.contains(where: { !isLowercaseSHA256($0) }) {
            append(.authoredFrameIndexHashInvalid, "One or more set provenance hashes are invalid.")
        }

        let ids = index.entries.map(\.prID)
        let paths = index.entries.map(\.manifestResourcePath)
        let manifestHashes = index.entries.map(\.manifestSHA256)
        if ids != ids.sorted() || Set(ids).count != 37 || Set(paths).count != 37 || Set(manifestHashes).count != 37 {
            append(.authoredFrameIndexInvalid, "Entries must be sorted with unique IDs, paths, and hashes.")
        }

        var speakerCounts: [String: Int] = [:]
        var surfaceCounts: [String: Int] = [:]
        var totalSamples = 0
        var totalFrames = 0
        var totalSpeech = 0
        var totalFallback = 0
        var totalOverrides = 0
        var totalWarnings = 0
        var aggregatePoses = MindEyeAuthoredFrameIndex.Entry.PoseFrameCounts.zero
        for entry in index.entries {
            let expectedPath = "Turing/MindsEye/AudioFrames/\(entry.prID).mouthframes.json"
            if entry.manifestResourcePath != expectedPath ||
                entry.manifestResourcePath.contains("..") ||
                entry.manifestResourcePath.hasPrefix("/") {
                append(.authoredFrameIndexInvalid, "Entry \(entry.prID) has an unsafe or mismatched resource path.")
            }
            if entry.sampleCount <= 0 ||
                entry.frameCount <= 0 ||
                entry.poseFrameCounts.total != entry.frameCount ||
                entry.speechFrameCount < 0 ||
                entry.fallbackFrameCount < 0 ||
                entry.manualOverrideFrameCount < 0 ||
                entry.warningCount < 0 ||
                !entry.durationSeconds.isFinite ||
                abs(entry.durationSeconds - Double(entry.sampleCount) / 48_000) > 0.5 / 48_000 {
                append(.authoredFrameIndexInvalid, "Entry \(entry.prID) has inconsistent timeline or count values.")
            }
            if [entry.manifestSHA256, entry.descriptorSHA256, entry.audioSHA256, entry.transcriptSHA256]
                .contains(where: { !isLowercaseSHA256($0) }) {
                append(.authoredFrameIndexHashInvalid, "Entry \(entry.prID) contains an invalid hash.")
            }
            speakerCounts[entry.speakerCharacterID.rawValue, default: 0] += 1
            surfaceCounts[entry.interactionSurface.rawValue, default: 0] += 1
            totalSamples += entry.sampleCount
            totalFrames += entry.frameCount
            totalSpeech += entry.speechFrameCount
            totalFallback += entry.fallbackFrameCount
            totalOverrides += entry.manualOverrideFrameCount
            totalWarnings += entry.warningCount
            aggregatePoses = aggregatePoses + entry.poseFrameCounts
        }

        if speakerCounts != expectedSpeakers || index.summary.speakerManifestCounts != expectedSpeakers {
            append(.authoredFrameIndexInvalid, "Speaker manifest counts do not match the 37-file corpus.")
        }
        if Set(surfaceCounts.keys) != expectedSurfaces || index.summary.surfaceManifestCounts != surfaceCounts {
            append(.authoredFrameIndexInvalid, "Surface manifest counts are invalid.")
        }
        if totalSamples != index.summary.totalSampleCount ||
            totalFrames != index.summary.totalFrameCount ||
            totalSpeech != index.summary.totalSpeechFrameCount ||
            totalFallback != index.summary.totalFallbackFrameCount ||
            totalOverrides != index.summary.totalManualOverrideFrameCount ||
            totalWarnings != index.summary.totalWarningCount ||
            aggregatePoses != index.summary.aggregatePoseFrameCounts ||
            index.summary.manifestBytes <= 0 {
            append(.authoredFrameIndexInvalid, "Index aggregate totals do not match its entries.")
        }
        let exactDuration = Double(totalSamples) / 48_000
        if !index.summary.totalDurationSeconds.isFinite ||
            abs(index.summary.totalDurationSeconds - exactDuration) > 0.5 / 48_000 {
            append(.authoredFrameIndexInvalid, "Aggregate duration does not match the exact sample count.")
        }
        let poses = aggregatePoses
        if [poses.rest, poses.small, poses.wide, poses.round, poses.teeth].min() ?? 0 <= 0 {
            append(.authoredFrameIndexInvalid, "All five semantic mouth poses must occur in the complete corpus.")
        }
        return failures
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

nonisolated struct MindEyeAuthoredFrameIndexSnapshot:
    Sendable,
    Equatable
{
    let index: MindEyeAuthoredFrameIndex
    let entriesByPRID: [String: MindEyeAuthoredFrameIndex.Entry]

    init(index: MindEyeAuthoredFrameIndex) throws {
        let failures = MindEyeAuthoredFrameIndexValidator.validate(index)
        guard let first = failures.first else {
            self.index = index
            var map: [String: MindEyeAuthoredFrameIndex.Entry] = [:]
            map.reserveCapacity(index.entries.count)
            for entry in index.entries {
                guard map.updateValue(entry, forKey: entry.prID) == nil else {
                    throw MindEyeFailure(
                        code: .authoredFrameIndexInvalid,
                        characterID: entry.speakerCharacterID,
                        vignetteID: nil,
                        resourcePath: "Turing/MindsEye/AudioFrames/index.json",
                        message: "Duplicate authored PR ID in runtime index."
                    )
                }
            }
            entriesByPRID = map
            return
        }
        throw first
    }

    func entry(for prID: String) -> MindEyeAuthoredFrameIndex.Entry? {
        entriesByPRID[prID]
    }
}
