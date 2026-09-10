import Foundation

nonisolated struct CharacterVocalVisemeManifest: Decodable, Sendable, Equatable {
    struct Timeline: Decodable, Sendable, Equatable {
        let sampleRate: Int
        let sampleCount: Int
        let durationSeconds: Double
        let framesPerSecond: Int
        let samplesPerNominalFrame: Int
        let frameCount: Int
    }

    struct Alignment: Decodable, Sendable, Equatable {
        let mode: String
        let engine: String
        let engineVersion: String
        let engineCommit: String
        let resourceTreeSHA256: String
        let acousticModelSHA256: String
        let phoneLanguageModelSHA256: String
        let transcriptSHA256: String?
        let vadModelSHA256: String
        let phonePoseMapSHA256: String
        let speechBoundaryPolicy: String

        enum CodingKeys: String, CodingKey {
            case mode
            case engine
            case engineVersion
            case engineCommit
            case resourceTreeSHA256
            case acousticModelSHA256
            case phoneLanguageModelSHA256
            case transcriptSHA256
            case vadModelSHA256 = "VADModelSHA256"
            case phonePoseMapSHA256
            case speechBoundaryPolicy
        }
    }

    struct Run: Codable, Sendable, Equatable {
        let startFrame: Int
        let endFrameExclusive: Int
        let pose: MindEyeMouthPose
    }

    struct Summary: Decodable, Sendable, Equatable {
        let poseFrameCounts: [String: Int]
        let speechFrameCount: Int
        let silenceFrameCount: Int
        let unknownPhoneCount: Int
        let runCount: Int
        let warnings: [String]
    }

    let schemaVersion: Int
    let compilerVersion: String
    let trackID: String
    let characterID: String
    let role: CharacterVocalRole
    let audioFile: String
    let audioResourcePath: String
    let audioSHA256: String
    let blendShapeDescriptorResourcePath: String
    let blendShapeDescriptorSHA256: String
    let looping: Bool
    let timeline: Timeline
    let requiredPoseFamilies: [MindEyeMouthPose]
    let alignment: Alignment
    let runsSHA256: String
    let runs: [Run]
    let summary: Summary
}

