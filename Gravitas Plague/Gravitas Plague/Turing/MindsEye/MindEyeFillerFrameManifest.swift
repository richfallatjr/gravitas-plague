import Foundation

nonisolated struct MindEyeFillerFrameManifest: Decodable, Sendable, Equatable {
    struct Authoring: Decodable, Sendable, Equatable {
        let mode: TuringFillerAuthoringMode
        let transcriptSHA256: String?
        let nonverbalProfile: String?
    }

    struct Timeline: Decodable, Sendable, Equatable {
        let sampleRate: Int
        let sampleCount: Int
        let durationSeconds: Double
        let framesPerSecond: Int
        let samplesPerNominalFrame: Int
        let frameCount: Int
    }

    struct PoseRun: Decodable, Sendable, Equatable {
        let startFrame: Int
        let endFrameExclusive: Int
        let pose: MindEyeMouthPose
        let evidenceMask: Int
    }

    struct AnalysisProvenance: Decodable, Sendable, Equatable {
        let toolchainLockSHA256: String
        let compilerConfigSHA256: String
        let mfaRawOutputSHA256: String?
        let nonverbalConfigurationSHA256: String?
    }

    let schemaVersion: Int
    let trackVersion: String
    let compilerVersion: String
    let fillerID: String
    let speakerCharacterID: TuringConversationCharacterID
    let audioResourcePath: String
    let audioSHA256: String
    let descriptorSHA256: String
    let authoring: Authoring
    let timeline: Timeline
    let mouthLayerBits: [String: Int]
    let poseRuns: [PoseRun]
    let expandedFramesSHA256: String
    let analysisProvenance: AnalysisProvenance
}

nonisolated enum MindEyeFillerFrameManifestValidator {
    static func validate(_ manifest: MindEyeFillerFrameManifest) throws {
        guard manifest.schemaVersion == 1,
              manifest.trackVersion == "mind-eye-filler-track/1",
              manifest.compilerVersion == "mind-eye-filler-compiler/1.0.0",
              manifest.timeline.sampleRate == 48_000,
              manifest.timeline.framesPerSecond == 60,
              manifest.timeline.samplesPerNominalFrame == 800,
              manifest.timeline.sampleCount > 0,
              manifest.timeline.frameCount == (manifest.timeline.sampleCount + 799) / 800,
              !manifest.poseRuns.isEmpty else {
            throw failure(manifest, .authoredFrameManifestInvalid, "Invalid filler track header/timeline.")
        }
        var cursor = 0
        var previous: MindEyeMouthPose?
        for run in manifest.poseRuns {
            guard run.startFrame == cursor,
                  run.endFrameExclusive > run.startFrame,
                  run.endFrameExclusive <= manifest.timeline.frameCount,
                  run.pose != previous,
                  (0...127).contains(run.evidenceMask) else {
                throw failure(manifest, .authoredFrameManifestInvalid, "Filler pose runs are not compact and contiguous.")
            }
            cursor = run.endFrameExclusive
            previous = run.pose
        }
        guard cursor == manifest.timeline.frameCount else {
            throw failure(manifest, .authoredFrameManifestInvalid, "Filler pose runs do not cover the timeline.")
        }
    }

    private static func failure(
        _ manifest: MindEyeFillerFrameManifest,
        _ code: MindEyeFailureCode,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: code,
            characterID: manifest.speakerCharacterID,
            vignetteID: nil,
            resourcePath: manifest.audioResourcePath,
            message: message
        )
    }
}
