import Foundation

nonisolated struct MindEyeAuthoredFrameManifest:
    Decodable,
    Sendable,
    Equatable
{
    struct Timeline: Decodable, Sendable, Equatable {
        let sampleRate: Int
        let sampleCount: Int
        let durationSeconds: Double
        let framesPerSecond: Int
        let samplesPerNominalFrame: Int
        let frameCount: Int
    }

    struct Frame: Decodable, Sendable, Equatable {
        let frameIndex: Int
        let sampleStart: Int
        let sampleEnd: Int
        let pose: MindEyeMouthPose
        let layerMask: Int
        let speechActive: Bool
        let phone: String
        let evidenceMask: Int
    }

    struct Summary: Decodable, Sendable, Equatable {
        let poseFrameCounts: [String: Int]
        let speechFrameCount: Int
        let silenceFrameCount: Int
        let fallbackFrameCount: Int
        let manualOverrideFrameCount: Int
        let alignedWordCount: Int
        let transcriptTokenCount: Int
        let oovWords: [String]
        let g2pWords: [String]
        let warnings: [String]
    }

    struct AnalysisProvenance: Decodable, Sendable, Equatable {
        struct MFA: Decodable, Sendable, Equatable {
            let version: String
            let acousticModel: String
            let acousticModelVersion: String
            let dictionary: String
            let dictionaryVersion: String
            let g2pModel: String
            let g2pModelVersion: String
            let retryUsed: Bool
            let rawOutputSHA256: String
        }

        struct VAD: Decodable, Sendable, Equatable {
            let name: String
            let version: String
            let backend: String
            let modelSHA256: String
            let configurationSHA256: String
        }

        let toolchainLockSHA256: String
        let compilerConfigSHA256: String
        let phonemePoseMapSHA256: String
        let pronunciationOverridesSHA256: String
        let manualOverrideSHA256: String?
        let mfa: MFA
        let vad: VAD
    }

    let schemaVersion: Int
    let compilerVersion: String
    let prID: String
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID
    let descriptorResourcePath: String
    let descriptorSHA256: String
    let audioResourcePath: String
    let audioSHA256: String
    let transcriptSHA256: String
    let timeline: Timeline
    let mouthLayerBits: [String: Int]
    let requiredPoseFamilies: [MindEyeMouthPose]
    let analysisProvenance: AnalysisProvenance
    let framesSHA256: String
    let frames: [Frame]
    let summary: Summary
}

nonisolated enum MindEyeAuthoredFrameManifestValidator {
    private static let compilerVersion = "mind-eye-authored-frame-compiler/1.0.3"
    private static let poses: [MindEyeMouthPose] = [.rest, .small, .wide, .round, .teeth]
    private static let poseBits: [MindEyeMouthPose: Int] = [
        .rest: 1,
        .small: 2,
        .wide: 4,
        .round: 8,
        .teeth: 16,
    ]

    static func validate(
        _ manifest: MindEyeAuthoredFrameManifest
    ) -> [MindEyeFailure] {
        var failures: [MindEyeFailure] = []

        func append(_ code: MindEyeFailureCode, _ message: String) {
            failures.append(MindEyeFailure(
                code: code,
                characterID: manifest.speakerCharacterID,
                vignetteID: nil,
                resourcePath: manifest.audioResourcePath,
                message: message
            ))
        }

        guard manifest.schemaVersion == 1,
              manifest.compilerVersion == compilerVersion else {
            append(.authoredFrameManifestUnsupported, "Unsupported authored frame schema/compiler.")
            return failures
        }
        guard manifest.timeline.sampleRate == 48_000,
              manifest.timeline.framesPerSecond == 60,
              manifest.timeline.samplesPerNominalFrame == 800,
              manifest.timeline.sampleCount > 0,
              manifest.timeline.frameCount == (manifest.timeline.sampleCount + 799) / 800,
              manifest.frames.count == manifest.timeline.frameCount,
              !manifest.frames.isEmpty else {
            append(.authoredFrameManifestInvalid, "The fixed 48 kHz/60 Hz timeline contract is invalid.")
            return failures
        }
        let exactBits = Dictionary(uniqueKeysWithValues: poses.map { ($0.rawValue, poseBits[$0]!) })
        if manifest.mouthLayerBits != exactBits || manifest.requiredPoseFamilies != poses {
            append(.authoredFrameManifestInvalid, "The five semantic pose families/bits are invalid.")
        }
        let duration = Double(manifest.timeline.sampleCount) / 48_000
        if !manifest.timeline.durationSeconds.isFinite ||
            abs(manifest.timeline.durationSeconds - duration) > 0.5 / 48_000 {
            append(.authoredFrameManifestInvalid, "Duration does not match the exact sample count.")
        }

        var expectedStart = 0
        var poseCounts = Dictionary(uniqueKeysWithValues: poses.map { ($0.rawValue, 0) })
        var speechCount = 0
        var fallbackCount = 0
        var overrideCount = 0
        for (index, frame) in manifest.frames.enumerated() {
            let expectedLength = index == manifest.frames.count - 1
                ? manifest.timeline.sampleCount - expectedStart
                : 800
            guard frame.frameIndex == index,
                  frame.sampleStart == expectedStart,
                  frame.sampleEnd > frame.sampleStart,
                  frame.sampleEnd - frame.sampleStart == expectedLength,
                  (1...800).contains(expectedLength),
                  poseBits[frame.pose] == frame.layerMask,
                  (0...65_535).contains(frame.evidenceMask),
                  frame.phone.utf8.count <= 65_535 else {
                append(.authoredFrameManifestInvalid, "Frame \(index) violates continuity, one-hot, or value bounds.")
                break
            }
            poseCounts[frame.pose.rawValue, default: 0] += 1
            speechCount += frame.speechActive ? 1 : 0
            fallbackCount += frame.evidenceMask & 32 == 0 ? 0 : 1
            overrideCount += frame.evidenceMask & 64 == 0 ? 0 : 1
            expectedStart = frame.sampleEnd
        }
        if expectedStart != manifest.timeline.sampleCount {
            append(.authoredFrameManifestInvalid, "Frames do not cover the complete sample timeline.")
        }
        if manifest.summary.poseFrameCounts != poseCounts ||
            manifest.summary.speechFrameCount != speechCount ||
            manifest.summary.silenceFrameCount != manifest.frames.count - speechCount ||
            manifest.summary.fallbackFrameCount != fallbackCount ||
            manifest.summary.manualOverrideFrameCount != overrideCount {
            append(.authoredFrameManifestInvalid, "Frame summary does not match frame data.")
        }

        let hashes: [String?] = [
            manifest.descriptorSHA256,
            manifest.audioSHA256,
            manifest.transcriptSHA256,
            manifest.framesSHA256,
            manifest.analysisProvenance.toolchainLockSHA256,
            manifest.analysisProvenance.compilerConfigSHA256,
            manifest.analysisProvenance.phonemePoseMapSHA256,
            manifest.analysisProvenance.pronunciationOverridesSHA256,
            manifest.analysisProvenance.manualOverrideSHA256,
            manifest.analysisProvenance.mfa.rawOutputSHA256,
            manifest.analysisProvenance.vad.modelSHA256,
            manifest.analysisProvenance.vad.configurationSHA256,
        ]
        if hashes.compactMap({ $0 }).contains(where: { !isLowercaseSHA256($0) }) {
            append(.authoredFrameManifestHashInvalid, "One or more provenance hashes are invalid.")
        }
        if manifest.analysisProvenance.mfa.version != "3.3.9" ||
            manifest.analysisProvenance.vad.version != "6.2.1" ||
            manifest.analysisProvenance.vad.backend != "onnx" {
            append(.authoredFrameManifestUnsupported, "Authored analysis provenance is unsupported.")
        }
        return failures
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
