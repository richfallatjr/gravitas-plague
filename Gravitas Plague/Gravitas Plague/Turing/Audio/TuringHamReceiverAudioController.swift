import RealityKit

@MainActor
final class TuringHamReceiverAudioController {
    private let bed:
        any TuringHamReceiverBedControlling
    private let tuningLoops:
        TuringRandomTuningLoopActor
    private var installationTask:
        Task<Void, Never>?

    init(
        bed:
            any TuringHamReceiverBedControlling =
                TuringHamReceiverBedActor.shared,
        tuningLoops:
            TuringRandomTuningLoopActor =
                .hamReceiver
    ) {
        self.bed = bed
        self.tuningLoops = tuningLoops
    }

    func prepareResources() async throws {
        if let installationTask {
            await installationTask.value
            self.installationTask = nil
        }
        try await bed.prepareResources()
        try await tuningLoops.prepareResources()
    }

    func install(emitter: Entity) async throws {
        if let installationTask {
            await installationTask.value
        }
        TuringHamReceiverAudioRoute.install(
            on: emitter
        )
        let endpoint =
            try TuringHamReceiverAudioRoute
                .requireActiveEndpoint()
        let task = Task {
            await bed.install(endpoint: endpoint)
            await tuningLoops.install(
                endpoint: endpoint
            )
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
            await tuningLoops.reset(
                reason: reason
            )
            await bed.reset(reason: reason)
            TuringHamReceiverAudioRoute.clear(
                reason: reason
            )
        }
    }

    func unload(reason: String) {
        let priorTask = installationTask
        priorTask?.cancel()
        installationTask = Task {
            await priorTask?.value
            await tuningLoops.unload(
                reason: reason
            )
            await bed.unload(reason: reason)
            TuringHamReceiverAudioRoute.clear(
                reason: reason
            )
        }
    }
}
