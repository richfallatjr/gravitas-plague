import Foundation

nonisolated struct TuringGeneratedSpeechSegmentIdentity:
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    let runID: String
    let segmentIndex: Int
    let speakerCharacterID: TuringConversationCharacterID
    let sourceTextSHA256: String
}
