import Foundation

@MainActor
final class TuringStoryStateTeleportCoordinator {
    static let shared = TuringStoryStateTeleportCoordinator()

    private weak var world: (any TuringStoryStateTeleportWorld)?
    private var activeTeleportID: UUID?

    func attach(_ world: any TuringStoryStateTeleportWorld) {
        self.world = world
    }

    func detach(_ world: any TuringStoryStateTeleportWorld) {
        guard self.world === world else { return }
        self.world = nil
    }

    func apply(_ destination: TuringStoryDestination, source: String) async throws {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw TuringStoryContinuationError.storyStageNotEstablished
        }
        guard activeTeleportID == nil else {
            throw TuringStoryContinuationError.teleportAlreadyActive
        }
        guard let world else {
            throw TuringStoryContinuationError.missingWorldAdapter
        }

        let teleportID = UUID()
        activeTeleportID = teleportID
        defer {
            if activeTeleportID == teleportID { activeTeleportID = nil }
        }

        let before = try world.establishedLayoutFingerprint()
        print("""
        [TuringStoryTeleport] started
          teleportID: \(teleportID.uuidString)
          source: \(source)
          episodeID: \(destination.episodeID.rawValue)
          checkpoint: \(destination.checkpoint)
          roomRescan: false
          placementRebuild: false
        """)

        try await world.quiesceStoryRuntime(teleportID: teleportID)
        await TuringEpisodeFlowController.shared.restore(
            completedScriptPointIDs: destination.completedScriptPointIDs,
            pendingConversationAdvance: destination.pendingConversationAdvance
        )

        if let scriptPointID = Self.conversationContextScriptPointID(
            for: destination.checkpoint
        ) {
            try await rehydratePrerecordingContext(
                for: scriptPointID
            )
        }

        try await world.applyDoorDestination(destination.doorState, teleportID: teleportID)
        try await world.applyBattleDestination(destination.battleState, teleportID: teleportID)
        try await world.applyMediaDestination(destination.mediaState, teleportID: teleportID)
        try await world.applyWalkieDestination(destination.walkieAction, teleportID: teleportID)

        let after = try world.establishedLayoutFingerprint()
        guard before == after else {
            assertionFailure("Story teleport changed the established room layout.")
            throw TuringStoryContinuationError.establishedLayoutChanged
        }

        print("""
        [TuringStoryTeleport] completed
          teleportID: \(teleportID.uuidString)
          roomRescan: false
          placementRebuild: false
          layoutFingerprintPreserved: true
        """)
    }

    nonisolated static func conversationContextScriptPointID(
        for checkpoint: TuringPrologueCheckpoint
    ) -> String? {
        switch checkpoint {
        case .script01PromptVoiceCompleted:
            return "prologue.scriptPoint01"
        case .script03PromptVoiceCompleted:
            return "prologue.scriptPoint03"
        case .notStarted,
             .script01ConversationVoiceCompleted,
             .script02PromptVoiceCompleted,
             .script04PromptVoiceCompleted,
             .script05PromptVoiceCompleted,
             .script04ConversationVoiceCompleted:
            return nil
        }
    }

    private func rehydratePrerecordingContext(
        for scriptPointID: String
    ) async throws {
        let descriptor = try TuringFlowDescriptorStore().require(
            scriptPointID
        )
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: descriptor.transmission.prerecordingID
        )
        guard prerecording.transcriptMode == .manual,
              prerecording.transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "\(scriptPointID) continuation requires its reviewed authored PR transcript."
            )
        }
        await TuringConversationInputStore.shared.updatePrerecording(
            id: prerecording.prerecordingID,
            transcript: prerecording.transcript,
            for: descriptor.transmission.conversationKey
        )
        let promptVoiceContext = try Self.promptVoiceContext(
            for: descriptor
        )
        await TuringConversationInputStore.shared
            .updatePromptVoiceStoryContext(
            promptVoiceContext.storyContext,
            for: descriptor.transmission.conversationKey
        )
        await TuringConversationInputStore.shared.updatePromptVariant(
            .forScriptPointID(descriptor.scriptPointID),
            for: descriptor.transmission.conversationKey
        )

        print("""
        [TuringContinuation] conversation PR context rehydrated
          scriptPointID: \(scriptPointID)
          conversationKey: \(descriptor.transmission.conversationKey)
          prerecordingID: \(prerecording.prerecordingID)
          transcriptMode: \(prerecording.transcriptMode.rawValue)
          transcriptUTF16: \(prerecording.transcript.utf16.count)
          promptVoiceID: \(promptVoiceContext.voicePromptID)
          promptVoiceStoryContextSHA256: \(TuringFlowHash.sha256(promptVoiceContext.storyContext))
          prerecordingReplayed: false
          promptVoiceReplayed: false
          continuationMetadataInjected: false
        """)
    }

    private nonisolated static func promptVoiceContext(
        for descriptor: TuringFlowDescriptor
    ) throws -> TuringAuthoredPromptVoiceContext {
        let promptStore = TuringVoicePromptTriggerStore()

        if let pipeline = descriptor.transmission.generationPipeline {
            guard pipeline.stages.count == 2,
                  let sourceResourcePath = pipeline.stages[0].sourceResourcePath,
                  let promptID = pipeline.stages[1].voicePromptID else {
                throw TuringRuntimeError.invalidConfig(
                    "\(descriptor.scriptPointID) continuation cannot reconstruct its promptVoice Story Context."
                )
            }
            let sourceURL = try TuringResourceLoader.resourceURL(
                resourcePath: sourceResourcePath
            )
            let sourceText = try String(
                contentsOf: sourceURL,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = try promptStore.descriptor(id: promptID)
            return TuringPromptVoiceStoryContextBuilder.composite(
                prompt,
                scriptVoiceSource: sourceText
            )
        }

        guard let promptID = descriptor.transmission.voicePromptID else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) continuation has no promptVoice Story Context."
            )
        }
        return TuringPromptVoiceStoryContextBuilder.standard(
            try promptStore.descriptor(id: promptID)
        )
    }
}
