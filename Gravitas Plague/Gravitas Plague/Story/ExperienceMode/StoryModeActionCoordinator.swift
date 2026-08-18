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

    private var queue: [PendingAction] = []
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

    func activate(_ action: PendingAction) {
        guard consumedBoundaryIDs.contains(action.durableBoundaryID) == false,
              queue.contains(where: {
                  $0.durableBoundaryID == action.durableBoundaryID
              }) == false else {
            return
        }
        queue.append(action)
        Task { [weak self] in
            await self?.drainIfPossible()
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
              let action = queue.first else {
            return
        }
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        guard runInFlight == false,
              queue.first == action,
              snapshot.exclusiveOwner == nil,
              snapshot.doorState == .closedUnloaded else {
            return
        }

        queue.removeFirst()

        consumedBoundaryIDs.insert(action.durableBoundaryID)
        runInFlight = true
        let activeGeneration = generation
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
