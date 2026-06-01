import Foundation
import Combine
import RealityKit

@MainActor
final class PlagueImmersiveCoordinator: ObservableObject {
    private let spatialProvider = PhaseOneSpatialProvider()

    private var sceneRoot: Entity?
    private var infectedController: BakedInfectedController?
    private var lastTickDate: Date?
    private var handledCommandIDs = Set<UUID>()
    private var pendingCommands: [PlagueDemoSession.CommandEnvelope] = []

    func makeSceneRoot() async -> Entity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = Entity()
        root.name = "GravitasPlague_PhaseOne_SceneRoot"

        await spatialProvider.start()

        let controller = BakedInfectedController(configuration: .phaseOneDefault)
        root.addChild(controller.rootEntity)

        do {
            try await controller.loadClips()

            let spawnPose = spatialProvider.currentPoseOrFallback()
            let config = PhaseOneConfiguration.phaseOneDefault
            let floorY = await spatialProvider.resolvedFloorY(
                for: spawnPose,
                fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
                timeoutSeconds: config.floorDetectionTimeoutSeconds
            )

            controller.configureSpawn(
                using: spawnPose,
                floorY: floorY
            )

            controller.prepareIdleAtSpawn()
        } catch {
            assertionFailure("Phase 1 failed to load baked USDZ clips: \(error)")
        }

        self.sceneRoot = root
        self.infectedController = controller

        drainPendingCommands()

        return root
    }

    func handle(_ envelope: PlagueDemoSession.CommandEnvelope) {
        guard !handledCommandIDs.contains(envelope.id) else { return }

        guard infectedController != nil else {
            pendingCommands.append(envelope)
            return
        }

        handledCommandIDs.insert(envelope.id)
        perform(envelope.command)
    }

    private func perform(_ command: PlagueDemoSession.Command) {
        switch command {
        case .startDemo:
            Task {
                await configureAndStartLoop()
            }

        case .resetDemo:
            Task {
                await configureAndResetLoop()
            }

        case .closeDemo:
            infectedController?.stopLoopAndHide()
            spatialProvider.stop()
        }
    }

    func tick(at date: Date) {
        let deltaTime: Float

        if let lastTickDate {
            deltaTime = min(Float(date.timeIntervalSince(lastTickDate)), 0.1)
        } else {
            deltaTime = 1.0 / 60.0
        }

        lastTickDate = date

        let currentHeadPosition = spatialProvider.currentPose()?.headPosition
        infectedController?.update(deltaTime: deltaTime, currentHeadPosition: currentHeadPosition)
    }

    func shutdown() {
        infectedController?.stopLoopAndHide()
        spatialProvider.stop()
        sceneRoot = nil
        infectedController = nil
        lastTickDate = nil
        handledCommandIDs.removeAll()
        pendingCommands.removeAll()
    }

    private func drainPendingCommands() {
        let commandsToDrain = pendingCommands
        pendingCommands.removeAll()

        for command in commandsToDrain {
            handle(command)
        }
    }

    private func configureAndStartLoop() async {
        guard let infectedController else { return }

        let spawnPose = spatialProvider.currentPoseOrFallback()
        let config = PhaseOneConfiguration.phaseOneDefault

        let floorY = await spatialProvider.resolvedFloorY(
            for: spawnPose,
            fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
            timeoutSeconds: config.floorDetectionTimeoutSeconds
        )

        infectedController.configureSpawn(
            using: spawnPose,
            floorY: floorY
        )

        infectedController.startLoop()
    }

    private func configureAndResetLoop() async {
        guard let infectedController else { return }

        let spawnPose = spatialProvider.currentPoseOrFallback()
        let config = PhaseOneConfiguration.phaseOneDefault

        let floorY = await spatialProvider.resolvedFloorY(
            for: spawnPose,
            fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
            timeoutSeconds: config.floorDetectionTimeoutSeconds
        )

        infectedController.configureSpawn(
            using: spawnPose,
            floorY: floorY
        )

        infectedController.resetLoopToIdleFar()
    }
}
