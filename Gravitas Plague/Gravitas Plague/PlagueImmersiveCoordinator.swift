import Foundation
import Combine
import RealityKit

@MainActor
final class PlagueImmersiveCoordinator: ObservableObject {
    private let poseProvider = DevicePoseProvider()

    private var sceneRoot: Entity?
    private var infectedController: BakedInfectedController?
    private var lastTickDate: Date?
    private var handledCommandIDs = Set<UUID>()

    func makeSceneRoot() async -> Entity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = Entity()
        root.name = "GravitasPlague_PhaseOne_SceneRoot"

        await poseProvider.start()

        let controller = BakedInfectedController(configuration: .phaseOneDefault)
        root.addChild(controller.rootEntity)

        do {
            try await controller.loadClips()
            let spawnPose = poseProvider.currentPoseOrFallback()
            controller.configureSpawn(using: spawnPose)
            controller.prepareIdleAtSpawn()
        } catch {
            assertionFailure("Phase 1 failed to load baked USDZ clips: \(error)")
        }

        self.sceneRoot = root
        self.infectedController = controller

        return root
    }

    func handle(_ envelope: PlagueDemoSession.CommandEnvelope) {
        guard !handledCommandIDs.contains(envelope.id) else { return }
        handledCommandIDs.insert(envelope.id)

        switch envelope.command {
        case .startDemo:
            let spawnPose = poseProvider.currentPoseOrFallback()
            infectedController?.configureSpawn(using: spawnPose)
            infectedController?.startLoop()

        case .resetDemo:
            let spawnPose = poseProvider.currentPoseOrFallback()
            infectedController?.configureSpawn(using: spawnPose)
            infectedController?.resetLoopToIdleFar()

        case .closeDemo:
            infectedController?.stopLoopAndHide()
            poseProvider.stop()
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

        let currentHeadPosition = poseProvider.currentPose()?.headPosition
        infectedController?.update(deltaTime: deltaTime, currentHeadPosition: currentHeadPosition)
    }

    func shutdown() {
        infectedController?.stopLoopAndHide()
        poseProvider.stop()
        sceneRoot = nil
        infectedController = nil
        lastTickDate = nil
        handledCommandIDs.removeAll()
    }
}
