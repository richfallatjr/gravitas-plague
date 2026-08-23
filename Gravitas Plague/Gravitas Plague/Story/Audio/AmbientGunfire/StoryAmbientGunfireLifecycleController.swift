import Foundation

nonisolated enum StoryAmbientGunfireSuppression: String, Hashable, Sendable {
    case titleCard
    case operationModeTeardown
    case immersiveShutdown
}

nonisolated struct StoryAmbientGunfireLifecycleState: Sendable, Equatable {
    private(set) var storyPropsCommitted = false
    private(set) var terminalAngelSequenceBegan = false
    private(set) var suppressions = Set<StoryAmbientGunfireSuppression>()

    var shouldRun: Bool {
        storyPropsCommitted &&
            !terminalAngelSequenceBegan &&
            suppressions.isEmpty
    }

    mutating func storyPropsDidCommit() {
        storyPropsCommitted = true
        suppressions.remove(.operationModeTeardown)
    }

    mutating func setTitleCardActive(_ active: Bool) {
        if active {
            suppressions.insert(.titleCard)
        } else {
            suppressions.remove(.titleCard)
        }
    }

    mutating func beginTerminalAngelSequence() {
        terminalAngelSequenceBegan = true
    }

    mutating func deactivate(_ suppression: StoryAmbientGunfireSuppression) {
        suppressions.insert(suppression)
        storyPropsCommitted = false
    }
}

@MainActor
final class StoryAmbientGunfireLifecycleController {
    private let channel: StoryAmbientGroundChannel
    private let scheduler: StoryAmbientGunfireScheduler
    private let worldBridge: StoryAmbientGunfireWorldBridge
    private var state = StoryAmbientGunfireLifecycleState()
    private var reconcileRevision = 0
    private var reconcileTask: Task<Void, Never>?

    init(
        channel: StoryAmbientGroundChannel = .gunfire,
        scheduler: StoryAmbientGunfireScheduler,
        worldBridge: StoryAmbientGunfireWorldBridge
    ) {
        self.channel = channel
        self.scheduler = scheduler
        self.worldBridge = worldBridge
    }

    func storyPropsDidCommit(reason: String) {
        state.storyPropsDidCommit()
        reconcile(reason: "propsCommitted.\(reason)")
    }

    func setTitleCardActive(_ active: Bool, reason: String) {
        state.setTitleCardActive(active)
        reconcile(reason: "titleCard.\(active).\(reason)")
    }

    func finalAngelDeathSequenceBegan(reason: String) {
        guard !state.terminalAngelSequenceBegan else { return }
        state.beginTerminalAngelSequence()
        worldBridge.stopActive(reason: "terminalAngelSequence.\(reason)")
        reconcile(reason: "terminalAngelSequence.\(reason)")
        print(
            "[\(channel.logName)] terminal cutoff latched " +
                "reason=\(reason) resumes=false"
        )
    }

    func deactivateAndWait(reason: String) async {
        state.deactivate(.operationModeTeardown)
        reconcileTask?.cancel()
        reconcileTask = nil
        worldBridge.stopActive(reason: reason)
        await scheduler.suspend(reason: reason)
    }

    func shutdown(reason: String) {
        state.deactivate(.immersiveShutdown)
        reconcileTask?.cancel()
        reconcileTask = nil
        worldBridge.stopActive(reason: reason)
        Task {
            await scheduler.suspend(reason: reason)
        }
    }

    private func reconcile(reason: String) {
        reconcileRevision += 1
        let revision = reconcileRevision
        let shouldRun = state.shouldRun
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self, scheduler] in
            guard let self else { return }
            if shouldRun {
                await scheduler.activate(reason: reason)
            } else {
                await scheduler.suspend(reason: reason)
            }
            guard !Task.isCancelled,
                  self.reconcileRevision == revision else { return }
            self.reconcileTask = nil
        }
    }
}
