import Foundation

nonisolated enum TuringFillerAuthoringMode:
    String,
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    case manualTranscript
    case nonverbal
    case untrackedFallback
}

nonisolated struct TuringFillerClipIdentity:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    let fillerID: String
    let speakerCharacterID: TuringConversationCharacterID
    let audioResourcePath: String
    let audioSHA256: String?
    let trackResourcePath: String?
    let trackSHA256: String?

    var stableMediaIdentity: String {
        let hash = audioSHA256.map { String($0.prefix(12)) } ?? "untracked"
        return ["filler", speakerCharacterID.rawValue, fillerID, hash]
            .joined(separator: ".")
    }
}

nonisolated struct TuringFillerClipDescriptor:
    Sendable,
    Equatable,
    Hashable
{
    let identity: TuringFillerClipIdentity
    let fileURL: URL
    let weight: Int
    let authoringMode: TuringFillerAuthoringMode

    var isTrackedForMindEye: Bool {
        identity.audioSHA256 != nil &&
            identity.trackResourcePath != nil &&
            identity.trackSHA256 != nil
    }
}

nonisolated struct TuringFillerCatalog: Sendable, Equatable {
    let clips: [TuringFillerClipDescriptor]

    var uniqueClipCount: Int { clips.count }
    var weightedEntryCount: Int { clips.reduce(0) { $0 + $1.weight } }
}

nonisolated enum TuringWeightedFillerSelector {
    static func select(
        clips: [TuringFillerClipDescriptor],
        avoiding fillerID: String?,
        draw: UInt64
    ) -> TuringFillerClipDescriptor? {
        guard !clips.isEmpty else { return nil }
        let candidates: [TuringFillerClipDescriptor]
        if clips.count > 1, let fillerID {
            let filtered = clips.filter { $0.identity.fillerID != fillerID }
            candidates = filtered.isEmpty ? clips : filtered
        } else {
            candidates = clips
        }
        let total = candidates.reduce(0) { $0 + max(1, $1.weight) }
        guard total > 0 else { return candidates.first }
        var cursor = Int(draw % UInt64(total))
        for clip in candidates {
            let weight = max(1, clip.weight)
            if cursor < weight { return clip }
            cursor -= weight
        }
        return candidates.last
    }
}
