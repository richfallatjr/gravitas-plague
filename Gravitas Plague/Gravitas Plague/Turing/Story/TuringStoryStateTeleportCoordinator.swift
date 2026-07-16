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

        if destination.checkpoint == .script01PromptVoiceCompleted {
            try await rehydrateScript01Prerecording()
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

    private func rehydrateScript01Prerecording() async throws {
        let descriptor = try TuringFlowDescriptorStore().require("prologue.scriptPoint01")
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: descriptor.transmission.prerecordingID
        )
        await TuringConversationSeedStore.shared.updatePrerecording(
            id: prerecording.prerecordingID,
            transcript: prerecording.transcript,
            for: descriptor.transmission.conversationKey
        )
    }
}
