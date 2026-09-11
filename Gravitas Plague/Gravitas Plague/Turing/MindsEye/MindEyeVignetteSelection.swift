nonisolated struct MindEyeVignetteSelection:
    Sendable,
    Equatable,
    Hashable
{
    let characterID: TuringConversationCharacterID
    let preferredVignetteID: String?

    init(
        characterID: TuringConversationCharacterID,
        run: TuringSpokenPresentationRunIdentity? = nil
    ) {
        self.characterID = characterID
        preferredVignetteID = MindEyeVignetteSelectionPolicy.preferredVignetteID(
            characterID: characterID,
            run: run
        )
    }

    init(continuity: TuringSpokenPresentationContinuity) {
        characterID = continuity.speakerCharacterID
        preferredVignetteID = MindEyeVignetteSelectionPolicy.preferredVignetteID(
            characterID: continuity.speakerCharacterID,
            continuity: continuity
        )
    }
}

nonisolated enum MindEyeVignetteSelectionPolicy {
    static let chapter03BigMikeVignetteID = "big_mike_damaged"

    static func preferredVignetteID(
        characterID: TuringConversationCharacterID,
        run: TuringSpokenPresentationRunIdentity?
    ) -> String? {
        guard characterID == .bigMike,
              let run else { return nil }
        if isChapter03(run.scriptPointID) ||
            isChapter03(run.playbackRunID) ||
            run.continuity.map(belongsToChapter03) == true {
            return chapter03BigMikeVignetteID
        }
        return nil
    }

    static func preferredVignetteID(
        characterID: TuringConversationCharacterID,
        continuity: TuringSpokenPresentationContinuity
    ) -> String? {
        guard characterID == .bigMike,
              belongsToChapter03(continuity) else { return nil }
        return chapter03BigMikeVignetteID
    }

    private static func belongsToChapter03(
        _ continuity: TuringSpokenPresentationContinuity
    ) -> Bool {
        guard let parent = continuity.parent else { return false }
        return isChapter03(parent.playbackRunID) ||
            isChapter03(parent.mediaIdentity)
    }

    private static func isChapter03(_ identity: String) -> Bool {
        identity.hasPrefix("chapter03.") || identity.contains(".chapter03.")
    }
}
