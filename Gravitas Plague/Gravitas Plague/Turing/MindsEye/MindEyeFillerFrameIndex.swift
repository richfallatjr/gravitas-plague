import Foundation

nonisolated struct MindEyeFillerFrameIndex: Decodable, Sendable, Equatable {
    struct Entry: Decodable, Sendable, Equatable {
        let fillerID: String
        let speakerCharacterID: TuringConversationCharacterID
        let audioResourcePath: String
        let audioSHA256: String
        let weight: Int
        let authoringMode: TuringFillerAuthoringMode
        let trackResourcePath: String
        let trackSHA256: String
        let sampleRate: Int
        let sampleCount: Int
        let frameCount: Int
        let durationSeconds: Double
        let poseRunCount: Int
    }

    let schemaVersion: Int
    let indexVersion: String
    let compilerVersion: String
    let registrySHA256: String
    let toolchainLockSHA256: String
    let expectedUniqueClipCounts: [String: Int]
    let expectedWeightedTotals: [String: Int]
    let manifestSetSHA256: String
    let entries: [Entry]
}

nonisolated struct MindEyeFillerFrameIndexSnapshot: Sendable, Equatable {
    let entriesByFillerID: [String: MindEyeFillerFrameIndex.Entry]

    init(index: MindEyeFillerFrameIndex) throws {
        guard index.schemaVersion == 1,
              index.indexVersion == "mind-eye-filler-index/1",
              index.compilerVersion == "mind-eye-filler-compiler/1.0.0",
              index.entries.count == 51,
              index.expectedUniqueClipCounts == ["big_mike": 27, "rich": 24],
              index.expectedWeightedTotals == ["big_mike": 132, "rich": 120] else {
            throw MindEyeFailure(
                code: .authoredFrameIndexInvalid,
                characterID: nil,
                vignetteID: nil,
                resourcePath: "Turing/MindsEye/Fillers/index.json",
                message: "Published filler index violates the 51-track corpus contract."
            )
        }
        let pairs = index.entries.map { ($0.fillerID, $0) }
        guard Set(pairs.map(\.0)).count == pairs.count else {
            throw MindEyeFailure(
                code: .authoredFrameIndexInvalid,
                characterID: nil,
                vignetteID: nil,
                resourcePath: "Turing/MindsEye/Fillers/index.json",
                message: "Published filler index contains duplicate IDs."
            )
        }
        entriesByFillerID = Dictionary(uniqueKeysWithValues: pairs)
    }
}
