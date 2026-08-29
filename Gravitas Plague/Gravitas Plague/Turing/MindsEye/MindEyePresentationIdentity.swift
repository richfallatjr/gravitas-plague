import Foundation

nonisolated struct MindEyePresentationKey:
    Sendable,
    Equatable,
    Hashable
{
    let playbackRunID: String
    let playbackHandleID: UUID

    init(
        playbackRunID: String,
        playbackHandleID: UUID
    ) {
        self.playbackRunID = playbackRunID
        self.playbackHandleID = playbackHandleID
    }

    init(context: TuringSpokenPresentationContext) {
        playbackRunID = context.run.playbackRunID
        playbackHandleID = context.playbackHandle.id
    }
}

nonisolated struct MindEyePresentationIdentity:
    Sendable,
    Equatable
{
    let key: MindEyePresentationKey
    let flowInstanceID: UUID
    let scriptPointID: String
    let mediaIdentity: String
    let speakerCharacterID: TuringConversationCharacterID
    let interactionSurface: StoryInteractionSurfaceID

    init(context: TuringSpokenPresentationContext) {
        key = MindEyePresentationKey(context: context)
        flowInstanceID = context.run.flowInstanceID
        scriptPointID = context.run.scriptPointID
        mediaIdentity = context.source.mediaIdentity
        speakerCharacterID = context.speakerCharacterID
        interactionSurface = context.interactionSurface
    }
}

nonisolated extension MindEyePresentationIdentity {
    func makeMotionSeedDescriptor(
        vignetteID: String
    ) -> MindEyeMotionSeedDescriptor {
        MindEyeMotionSeedDescriptor(
            vignetteID: vignetteID,
            speakerCharacterID: speakerCharacterID.rawValue,
            playbackRunID: key.playbackRunID,
            flowInstanceID: flowInstanceID,
            sourceIdentity: mediaIdentity
        )
    }
}
