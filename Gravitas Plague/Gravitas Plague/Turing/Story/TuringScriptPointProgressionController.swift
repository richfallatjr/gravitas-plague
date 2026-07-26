import Foundation

/// Compatibility facade for old call sites.
///
/// Production progression is owned by `TuringEpisodeFlowController`. This actor
/// contains no ScriptPoint orchestration and no hardcoded 02/03 runner.
actor TuringScriptPointProgressionController {
    static let shared =
        TuringScriptPointProgressionController()

    func triggerAfterFirstSuccessfulWalkieCustomMessage(
        inputStore _: TuringConversationInputStore = .shared
    ) async -> TuringVoiceRunResult? {
        await TuringEpisodeFlowController
            .shared
            .conversationPlaybackCompleted(
                conversationKey:
                    TuringDialogueThreadIdentity
                        .bigMikeRich
            )
    }

    func markCompletedByManualRun() async {
        await TuringEpisodeFlowController
            .shared
            .markCompletedForCompatibility(
                [
                    "prologue.scriptPoint02",
                    "prologue.scriptPoint03"
                ]
            )
    }
}
