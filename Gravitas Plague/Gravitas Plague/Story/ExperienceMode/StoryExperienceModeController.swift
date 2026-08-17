import Combine
import Foundation

@MainActor
final class StoryExperienceModeController: ObservableObject {
    static let shared = StoryExperienceModeController()

    @Published private(set) var mode: StoryExperienceMode = .play
    private(set) var revision: UInt64 = 0

    private var pendingMode: StoryExperienceMode?
    private var interactionTask: Task<Void, Never>?

    private init() {
        interactionTask = Task { [weak self] in
            let snapshots = await StoryInteractionArbiter.shared.snapshots()
            for await snapshot in snapshots {
                guard Task.isCancelled == false else { return }
                guard snapshot.exclusiveOwner == nil else { continue }
                await self?.applyPendingIfStable(source: "interactionStable")
            }
        }
    }

    deinit {
        interactionTask?.cancel()
    }

    func requestToggle(source: String) async {
        let destination = mode.toggleDestination
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        guard snapshot.exclusiveOwner == nil else {
            pendingMode = destination
            let owner = snapshot.exclusiveOwner?.logValue ?? "none"
            print(
                "[StoryExperienceMode] deferred destination=\(destination.rawValue) " +
                    "owner=\(owner) source=\(source)"
            )
            return
        }
        await commit(destination, source: source)
    }

    func modeForNewStoryAction() -> StoryExperienceMode {
        mode
    }

    private func applyPendingIfStable(source: String) async {
        guard let pendingMode else { return }
        let snapshot = await StoryInteractionArbiter.shared.currentSnapshot()
        guard snapshot.exclusiveOwner == nil else { return }
        self.pendingMode = nil
        await commit(pendingMode, source: source)
    }

    private func commit(
        _ newMode: StoryExperienceMode,
        source: String
    ) async {
        guard mode != newMode else { return }
        let oldMode = mode
        mode = newMode
        revision &+= 1
        await StoryInteractionArbiter.shared.updateExperienceMode(
            newMode,
            reason: source
        )
        StoryModeActionCoordinator.shared.modeDidCommit()
        print("""
        [StoryExperienceMode] committed
          oldMode: \(oldMode.rawValue)
          newMode: \(newMode.rawValue)
          revision: \(revision)
          persisted: false
          source: \(source)
        """)
    }
}
