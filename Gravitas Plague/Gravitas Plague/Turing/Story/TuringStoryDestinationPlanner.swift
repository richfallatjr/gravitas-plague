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
        for snapshot: TuringEpisodeContinuationSnapshot,
        experienceMode: StoryExperienceMode = .interactive
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
            if experienceMode == .play {
                return TuringStoryDestination(
                    episodeID: .prologue,
                    checkpoint: snapshot.checkpoint,
                    completedScriptPointIDs: ["prologue.scriptPoint01"],
                    pendingConversationAdvance: nil,
                    walkieAction: .play(
                        scriptPointID: "prologue.scriptPoint02",
                        trigger: .playModeAutoplay(
                            parentBoundaryID: "prologue.scriptPoint01"
                        )
                    ),
                    doorState: nil,
                    battleState: .absent,
                    mediaState: .silent
                )
            }
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
        case .script03PromptVoiceCompleted,
             .script04PromptVoiceCompleted,
             .script04ConversationVoiceCompleted,
             .script05PromptVoiceCompleted:
            return TuringStoryDestination(
                episodeID: .prologue,
                checkpoint: .script03PromptVoiceCompleted,
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
        }
    }
}
