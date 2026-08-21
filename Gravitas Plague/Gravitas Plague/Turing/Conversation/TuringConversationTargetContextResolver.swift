import Foundation

nonisolated enum TuringConversationTargetContextPosition:
    String,
    Codable,
    Sendable,
    Equatable
{
    case currentOrPrior
    case next
}

nonisolated struct TuringConversationTargetContextSelection:
    Sendable,
    Equatable
{
    let targetCharacterID: TuringConversationCharacterID
    let selectedMoment: TuringLiveConversationCatalog.Moment
    let position: TuringConversationTargetContextPosition
}

struct TuringConversationTargetContextResolver: Sendable {
    let catalog: TuringLiveConversationCatalog

    func resolve(
        episodeID: TuringEpisodeID,
        currentMoment: TuringLiveConversationCatalog.Moment
    ) throws -> TuringConversationTargetContextSelection {
        guard let episode = catalog.episodes.first(
            where: { $0.episodeID == episodeID }
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation episode \(episodeID.rawValue) is missing."
            )
        }
        let target = currentMoment.conversationTargetCharacterID
        let candidates = episode.moments.filter {
            $0.interactionSurface == currentMoment.interactionSurface &&
                $0.speakerCharacterID == target
        }.sorted {
            $0.narrativeOrdinal < $1.narrativeOrdinal
        }

        if let latest = candidates.last(where: {
            $0.narrativeOrdinal <= currentMoment.narrativeOrdinal
        }) {
            return TuringConversationTargetContextSelection(
                targetCharacterID: target,
                selectedMoment: latest,
                position: .currentOrPrior
            )
        }
        guard let next = candidates.first(where: {
            $0.narrativeOrdinal > currentMoment.narrativeOrdinal
        }) else {
            throw TuringRuntimeError.invalidConfig(
                "No PromptVoice context exists for \(target.rawValue) at \(currentMoment.momentID)."
            )
        }
        return TuringConversationTargetContextSelection(
            targetCharacterID: target,
            selectedMoment: next,
            position: .next
        )
    }
}
