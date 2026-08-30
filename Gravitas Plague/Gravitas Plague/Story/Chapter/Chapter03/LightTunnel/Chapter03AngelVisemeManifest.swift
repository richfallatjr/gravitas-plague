import Foundation

nonisolated struct Chapter03AngelVisemeSummary: Decodable, Sendable, Equatable {
    let poseFrameCounts: [String: Int]
    let speechFrameCount: Int
    let silenceFrameCount: Int
    let unknownPhoneCount: Int
    let runCount: Int
    let warnings: [String]
}

nonisolated struct Chapter03AngelVisemeManifest: Decodable, Sendable, Equatable {
    struct Timeline: Decodable, Sendable, Equatable {
        let sampleRate: Int
        let sampleCount: Int
        let durationSeconds: Double
        let framesPerSecond: Int
        let samplesPerNominalFrame: Int
        let frameCount: Int
    }

    struct Run: Codable, Sendable, Equatable {
        let startFrame: Int
        let endFrameExclusive: Int
        let pose: MindEyeMouthPose
    }

    struct Alignment: Decodable, Sendable, Equatable {
        let mode: String
        let engine: String
        let engineVersion: String
        let acousticModelSHA256: String
        let phoneLanguageModelSHA256: String?
        let transcriptSHA256: String?
        let VADModelSHA256: String
        let phonePoseMapSHA256: String
    }

    let schemaVersion: Int
    let compilerVersion: String
    let trackID: String
    let sourceCinematicID: String
    let descriptorResourcePath: String
    let descriptorSHA256: String
    let audioResourcePath: String
    let audioSHA256: String
    let timeline: Timeline
    let requiredPoseFamilies: [MindEyeMouthPose]
    let densityMultipliers: [String: Float]
    let alignment: Alignment
    let runsSHA256: String
    let runs: [Run]
    let summary: Chapter03AngelVisemeSummary
}
