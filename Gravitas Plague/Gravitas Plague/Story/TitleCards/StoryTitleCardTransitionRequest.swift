import Foundation

enum StoryTitleCardDestination: Sendable, Equatable {
    case start(TuringEpisodeID)
    case continueFrom(TuringStoryContinuationTarget)
    case advance(from: TuringEpisodeID, to: TuringEpisodeID)
    case endOfAvailableContent(completedEpisode: TuringEpisodeID)

    var episodeID: TuringEpisodeID {
        switch self {
        case .start(let episodeID):
            return episodeID
        case .continueFrom(let target):
            return target.episodeID
        case .advance(_, let next):
            return next
        case .endOfAvailableContent(let completedEpisode):
            return completedEpisode
        }
    }

    var stopsPrologueAftermathAfterFade: Bool {
        switch self {
        case .start(.chapter01),
             .continueFrom(.chapter01),
             .advance(from: .prologue, to: .chapter01):
            return true
        case .start,
             .continueFrom,
             .advance,
             .endOfAvailableContent:
            return false
        }
    }
}

enum StoryTitleCardMenuMusicPolicy: String, Sendable, Equatable {
    case stopOnAcceptance
    case playThroughCard
    case unchanged
}

struct StoryTitleCardTransitionRequest: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case episodePickerStart
        case episodePickerContinue
        case naturalEpisodeBoundary
    }

    let requestID: UUID
    let source: Source
    let descriptor: StoryTitleCardDescriptor
    let destination: StoryTitleCardDestination
    let menuMusicPolicy: StoryTitleCardMenuMusicPolicy
}

enum StoryTitleCardLeaseOrigin: Sendable {
    case acquireFromStableState
    case transferred(StoryInteractionLease)
}

enum StoryTitleCardRouteLeaseDisposition: Sendable, Equatable {
    case releaseAfterFade
    case retainedByDestination
    case transferredByDestination
}

nonisolated struct StoryEpisodeBoundaryEvent: Sendable, Hashable {
    let eventID: UUID
    let completedEpisodeID: TuringEpisodeID
    let actualTerminalPlaybackCompleted: Bool
}
