import Foundation

nonisolated struct MindEyeResponsePresentationKey:
    Sendable,
    Equatable,
    Hashable
{
    let playbackRunID: String
    let flowInstanceID: UUID
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID

    init(context: TuringSpokenPresentationContext) {
        playbackRunID = context.run.playbackRunID
        flowInstanceID = context.run.flowInstanceID
        speakerCharacterID = context.speakerCharacterID
        interactionSurface = context.interactionSurface
    }
}

nonisolated extension TuringSpokenPresentationContext {
    var responsePresentationKey: MindEyeResponsePresentationKey? {
        source.participatesInResponseContinuity
            ? MindEyeResponsePresentationKey(context: self)
            : nil
    }
}
