import Foundation

enum TuringStoryDestinationPlanner {
    static func startOfEpisode(_ episodeID: TuringEpisodeID) throws -> TuringStoryDestination {
        guard episodeID == .prologue else {
            throw TuringStoryContinuationError.unsupportedEpisode
        }
        return TuringStoryDestination(
            episodeID: .prologue,
            checkpoint: .notStarted,
            completedScriptPointIDs: [],
            pendingConversationAdvance: nil,
            walkieAction: .play(
                scriptPointID: "prologue.scriptPoint01",
                trigger: .userPlay
            ),
            doorState: .closed,
            battleState: .absent,
            mediaState: .silent
        )
    }

    static func destination(
        for snapshot: TuringEpisodeContinuationSnapshot
    ) throws -> TuringStoryDestination {
        guard snapshot.schemaVersion == TuringEpisodeContinuationSnapshot.currentSchemaVersion,
              snapshot.episodeID == .prologue,
              snapshot.contentRevision == TuringStoryProgressStore.prologueContentRevision else {
            throw TuringStoryContinuationError.contentRevisionMismatch
        }

        switch snapshot.checkpoint {
        case .notStarted:
            return try startOfEpisode(.prologue)
        case .script01PromptVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: ["prologue.scriptPoint01"],
                pendingConversationAdvance: RestoredPendingConversationAdvance(
                    parentScriptPointID: "prologue.scriptPoint01",
                    nextScriptPointID: "prologue.scriptPoint02",
                    conversationKey: TuringDialogueThreadIdentity.bigMikeRich
                ),
                walkieAction: .microphone,
                doorState: nil,
                battleState: .absent,
                mediaState: .silent
            )
        case .script01ConversationVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: ["prologue.scriptPoint01"],
                pendingConversationAdvance: nil,
                walkieAction: .play(
                    scriptPointID: "prologue.scriptPoint02",
                    trigger: .continuationRestore(checkpoint: snapshot.checkpoint)
                ),
                doorState: nil,
                battleState: .absent,
                mediaState: .silent
            )
        case .script02PromptVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02"
                ],
                pendingConversationAdvance: nil,
                walkieAction: .play(
                    scriptPointID: "prologue.scriptPoint03",
                    trigger: .continuationRestore(checkpoint: snapshot.checkpoint)
                ),
                doorState: nil,
                battleState: .absent,
                mediaState: .silent
            )
        case .script03PromptVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02",
                    "prologue.scriptPoint03"
                ],
                pendingConversationAdvance: nil,
                walkieAction: .microphone,
                doorState: nil,
                battleState: .battle01Start,
                mediaState: .battle01
            )
        case .script04PromptVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02",
                    "prologue.scriptPoint03",
                    "prologue.scriptPoint04"
                ],
                pendingConversationAdvance: RestoredPendingConversationAdvance(
                    parentScriptPointID: "prologue.scriptPoint04",
                    nextScriptPointID: "prologue.scriptPoint05",
                    conversationKey: TuringDialogueThreadIdentity.bigMikeRich
                ),
                walkieAction: .microphone,
                doorState: nil,
                battleState: .battle01GrandmaDown,
                mediaState: .battle01Aftermath
            )
        case .script04ConversationVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02",
                    "prologue.scriptPoint03",
                    "prologue.scriptPoint04"
                ],
                pendingConversationAdvance: nil,
                walkieAction: .play(
                    scriptPointID: "prologue.scriptPoint05",
                    trigger: .continuationRestore(checkpoint: snapshot.checkpoint)
                ),
                doorState: nil,
                battleState: .battle01GrandmaDown,
                mediaState: .battle01Aftermath
            )
        case .script05PromptVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: snapshot.checkpoint,
                completedScriptPointIDs: [
                    "prologue.scriptPoint01",
                    "prologue.scriptPoint02",
                    "prologue.scriptPoint03",
                    "prologue.scriptPoint04",
                    "prologue.scriptPoint05"
                ],
                pendingConversationAdvance: nil,
                walkieAction: .microphone,
                doorState: nil,
                battleState: .battle01GrandmaDown,
                mediaState: .battle01Aftermath
            )
        }
    }
}
