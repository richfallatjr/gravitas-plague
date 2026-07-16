import Foundation

enum TuringPrologueCheckpoint: Int, Codable, Sendable, Comparable, CaseIterable {
    case notStarted = 0
    case script01PromptVoiceCompleted = 10
    case script01ConversationVoiceCompleted = 20
    case script02PromptVoiceCompleted = 30
    case script03PromptVoiceCompleted = 40

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TuringEpisodeContinuationSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let episodeID: TuringEpisodeID
    let checkpoint: TuringPrologueCheckpoint
    let revision: Int
    let committedAt: Date
    let sourceEventID: UUID
    let contentRevision: String
}
