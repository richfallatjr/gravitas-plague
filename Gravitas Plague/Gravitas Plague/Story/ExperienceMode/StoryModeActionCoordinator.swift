import Foundation

@MainActor
final class StoryModeActionCoordinator {
    static let shared = StoryModeActionCoordinator()

    struct PendingAction: Sendable, Equatable {
        let episodeID: TuringEpisodeID
        let rootScriptPointID: String
        let durableBoundaryID: String
        let sourceEventID: UUID
    }

    private struct QueuedAction {
        let action: PendingAction
        let interactiveArm: @MainActor () -> Void
    }

    private var queue: [QueuedAction] = []
    private var consumedBoundaryIDs = Set<String>()
    private var runInFlight = false
    private var generation: UInt64 = 0
    private var interactionTask: Task<Void, Never>?

    private init() {
        interactionTask = Task { [weak self] in
            let snapshots = await StoryInteractionArbiter.shared.snapshots()
            for await _ in snapshots {
                guard Task.isCancelled == false else { return }
                await self?.drainIfPossible()
            }
        }
    }

    deinit {
        interactionTask?.cancel()
    }

    func activate(
        _ action: PendingAction,
        mode: StoryExperienceMode,
        interactiveArm: @MainActor @escaping () -> Void
    ) {
        switch mode {
        case .interactive:
            interactiveArm()
        case .play:
            guard consumedBoundaryIDs.contains(action.durableBoundaryID) == false,
                  queue.contains(where: {
                      $0.action.durableBoundaryID == action.durableBoundaryID
                  }) == false else {
                return
            }
            queue.append(
                QueuedAction(
                    action: action,
                    interactiveArm: interactiveArm
                )
            )
            Task { [weak self] in
                await TuringFlowInteractionGateController.shared
                    .applyStableStatesAtomically(
                        Dictionary(
                            uniqueKeysWithValues:
                                StoryInteractionSurfaceID.allCases.map {
                                    ($0, .closed)
                                }
                        ),
                        reason: "playMode.pending.\(action.durableBoundaryID)"
                    )
                await self?.drainIfPossible()
            }
        }
    }

    func modeDidCommit() {
        Task { [weak self] in
            await self?.drainIfPossible()
        }
    }

    func reset(reason: String) {
        generation &+= 1
        queue.removeAll(keepingCapacity: false)
        consumedBoundaryIDs.removeAll(keepingCapacity: false)
        runInFlight = false
        print("[StoryPlayMode] pending actions reset reason=\(reason)")
    }

    private func drainIfPossible() async {
        guard runInFlight == false,
              let queued = queue.first else {
            return
        }
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        guard snapshot.exclusiveOwner == nil,
              snapshot.doorState == .closedUnloaded else {
            return
        }

        let mode = StoryExperienceModeController.shared.modeForNewStoryAction()
        queue.removeFirst()
        guard mode == .play else {
            queued.interactiveArm()
            return
        }

        consumedBoundaryIDs.insert(queued.action.durableBoundaryID)
        runInFlight = true
        let activeGeneration = generation
        let action = queued.action
        print("""
        [StoryPlayMode] action started
          episodeID: \(action.episodeID.rawValue)
          scriptPointID: \(action.rootScriptPointID)
          trigger: playModeAutoplay
          boundary: \(action.durableBoundaryID)
          foundationRequests: 0
          freshInstancesWarmed: 0
          qwenRenders: 0
          decoderRuns: 0
        """)
        Task { [weak self] in
            let result = await TuringEpisodeFlowController.shared.start(
                scriptPointID: action.rootScriptPointID,
                trigger: .playModeAutoplay(
                    parentBoundaryID: action.durableBoundaryID
                )
            )
            await MainActor.run {
                guard let self else { return }
                guard self.generation == activeGeneration else {
                    print(
                        "[StoryPlayMode] stale action completion ignored " +
                            "scriptPointID=\(action.rootScriptPointID)"
                    )
                    return
                }
                self.runInFlight = false
                if result.succeeded == false {
                    self.consumedBoundaryIDs.remove(action.durableBoundaryID)
                    print("[StoryPlayMode] action failed scriptPointID=\(action.rootScriptPointID) result=\(result)")
                }
                Task { [weak self] in
                    await self?.drainIfPossible()
                }
            }
        }
    }
}
