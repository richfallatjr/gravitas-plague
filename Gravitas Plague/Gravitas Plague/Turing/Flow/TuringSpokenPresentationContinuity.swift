import Foundation

nonisolated struct TuringSpokenPresentationContinuity:
    Sendable,
    Equatable,
    Hashable
{
    struct Parent: Sendable, Equatable, Hashable {
        let playbackRunID: String
        let flowInstanceID: UUID
        let mediaIdentity: String
    }

    let continuityID: UUID
    let parent: Parent?
    let childPlaybackRunID: String
    let childFlowInstanceID: UUID
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID
}
