import Foundation
import Combine
import RealityKit

@MainActor
final class PlagueImmersiveCoordinator: ObservableObject {
    private let spatialProvider = PhaseOneSpatialProvider()

    private var sceneRoot: Entity?

    private var bakedDemoController: BakedInfectedController?
    private var jockRetargetController: JockRetargetTestController?

    private var lastTickDate: Date?
    private var handledCommandIDs = Set<UUID>()
    private var pendingCommands: [PlagueDemoSession.CommandEnvelope] = []
    private var jockLoopEnabled = true

    func makeSceneRoot() async -> Entity {
        if let sceneRoot {
            return sceneRoot
        }

        let root = Entity()
        root.name = "GravitasPlague_PhaseOne_SceneRoot"

        await spatialProvider.start()

        let controller = BakedInfectedController(configuration: .phaseOneDefault)
        root.addChild(controller.rootEntity)

        let jockController = JockRetargetTestController()
        root.addChild(jockController.rootEntity)

        self.sceneRoot = root
        self.bakedDemoController = controller
        self.jockRetargetController = jockController

        drainPendingCommands()

        return root
    }

    func handle(_ envelope: PlagueDemoSession.CommandEnvelope) {
        guard !handledCommandIDs.contains(envelope.id) else { return }

        guard sceneRoot != nil else {
            pendingCommands.append(envelope)
            return
        }

        handledCommandIDs.insert(envelope.id)
        perform(envelope.command)
    }

    private func perform(_ command: PlagueDemoSession.Command) {
        switch command {
        case .startBakedUSDZDemo:
            Task {
                await startBakedDemo()
            }

        case .startJockRetargetTest:
            Task {
                await startJockRetargetTest()
            }

        case .playJockDummy:
            jockRetargetController?.playDummy(loop: jockLoopEnabled)

        case .stopJockDummy:
            jockRetargetController?.stopDummy()

        case .resetJockPose:
            jockRetargetController?.resetPose()

        case .setJockLoop(let enabled):
            jockLoopEnabled = enabled
            jockRetargetController?.setLoopEnabled(enabled)

        case .closeDemo:
            bakedDemoController?.stopLoopAndHide()
            jockRetargetController?.hide()
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

        bakedDemoController?.update(
            deltaTime: deltaTime,
            currentHeadPosition: currentHeadPosition
        )

        jockRetargetController?.update(deltaTime: deltaTime)
    }

    func shutdown() {
        bakedDemoController?.stopLoopAndHide()
        jockRetargetController?.hide()
        spatialProvider.stop()

        sceneRoot = nil
        bakedDemoController = nil
        jockRetargetController = nil
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

    private func startBakedDemo() async {
        jockRetargetController?.hide()

        guard let bakedDemoController else { return }

        do {
            try await bakedDemoController.loadClips()

            let spawnPose = spatialProvider.currentPoseOrFallback()
            let config = PhaseOneConfiguration.phaseOneDefault

            let floorY = await spatialProvider.resolvedFloorY(
                for: spawnPose,
                fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
                timeoutSeconds: config.floorDetectionTimeoutSeconds
            )

            bakedDemoController.configureSpawn(
                using: spawnPose,
                floorY: floorY
            )

            bakedDemoController.startLoop()
        } catch {
            assertionFailure("Failed to start baked USDZ demo: \(error)")
        }
    }

    private func startJockRetargetTest() async {
        bakedDemoController?.stopLoopAndHide()

        guard let jockRetargetController else { return }

        do {
            try await jockRetargetController.loadIfNeeded()

            let spawnPose = spatialProvider.currentPoseOrFallback()
            let config = PhaseOneConfiguration.phaseOneDefault

            let floorY = await spatialProvider.resolvedFloorY(
                for: spawnPose,
                fallbackHeadToFloorOffset: config.fallbackHeadToFloorOffset,
                timeoutSeconds: config.floorDetectionTimeoutSeconds
            )

            jockRetargetController.configureSpawn(
                using: spawnPose,
                floorY: floorY
            )

            jockRetargetController.show()
            jockRetargetController.playDummy(loop: jockLoopEnabled)
        } catch {
            assertionFailure("Failed to start Jock Retarget Test: \(error)")
        }
    }
}
