import RealityKit

@MainActor
final class TuringRollingBenchRadioController {
    private let worker:
        any TuringRollingBenchRadioBedControlling
    private let tuningLoops:
        TuringCrankRadioTuningLoopActor
    private var installationTask: Task<Void, Never>?

    convenience init() {
        self.init(
            worker:
                TuringRollingBenchRadioBedActor.shared,
            tuningLoops:
                TuringCrankRadioTuningLoopActor.shared
        )
    }

    init(
        worker:
            any TuringRollingBenchRadioBedControlling,
        tuningLoops:
            TuringCrankRadioTuningLoopActor
    ) {
        self.worker = worker
        self.tuningLoops = tuningLoops
    }

    func prepareResources() async throws {
        if let installationTask {
            await installationTask.value
            self.installationTask = nil
        }
        try await worker.prepareResources()
        try await tuningLoops.prepareResources()
    }

    func install(emitter: Entity) async throws {
        if let installationTask {
            await installationTask.value
        }
        TuringRollingBenchAudioRoute.install(
            on: emitter
        )
        let endpoint =
            try TuringRollingBenchAudioRoute
                .requireActiveEndpoint()
        let task = Task {
            await worker.install(endpoint: endpoint)
            await tuningLoops.install(endpoint: endpoint)
        }
        installationTask = task
        await task.value
        installationTask = nil
    }

    func reset(reason: String) {
        let priorTask = installationTask
        priorTask?.cancel()
        installationTask = Task {
            await priorTask?.value
            await tuningLoops.reset(reason: reason)
            await worker.reset(reason: reason)
            TuringRollingBenchAudioRoute.clear(
                reason: reason
            )
        }
    }

    func unload(reason: String) {
        let priorTask = installationTask
        priorTask?.cancel()
        installationTask = Task {
            await priorTask?.value
            await tuningLoops.unload(reason: reason)
            await worker.unload(reason: reason)
            TuringRollingBenchAudioRoute.clear(
                reason: reason
            )
        }
    }
}
