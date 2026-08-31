import Foundation
import RealityKit
import simd

@MainActor
final class Chapter03LightTunnelPresenter {
    private let cinematicWorld: CinematicWorldPresentationCoordinator
    private let sceneFactory = Chapter03LightTunnelSceneFactory()
    private var sceneBundle: Chapter03LightTunnelSceneBundle?
    private var runID: UUID?
    private var root: Entity?
    private var portalTravelRoot: Entity?
    private var portalWorld: Entity?
    private var portalAperture: ModelEntity?
    private var portalDome: ModelEntity?
    private var portalIBLEntity: Entity?
    private var angel: Chapter03AngelPortalEntity?
    private var heavenPortalEmbers: Chapter03HeavenPortalEmberController?
    private var angelVisemeTrack: Chapter03AngelVisemeTrack?
    private var angelPerformance: Chapter03AngelPerformanceCoordinator?
    private var angelProjection: MindEyeAngelProjectionController?
    private(set) var angelAudioEmitter: Entity?
    private var lastLoggedDistanceBucket: Int?

    init(cinematicWorld: CinematicWorldPresentationCoordinator) {
        self.cinematicWorld = cinematicWorld
    }

    func prepare(
        runID: UUID,
        originFromDevice: simd_float4x4,
        definition: Chapter03LightTunnelVisualDefinition,
        angelVisemeTrack: Chapter03AngelVisemeTrack?
    ) async throws {
        remove(runID: self.runID, reason: "replacement")

        let bundle = try await sceneFactory.make(
            runID: runID,
            definition: definition,
            originFromDevice: originFromDevice,
            mode: .runtimePortal
        )
        let worldAnchor = try cinematicWorld.claimChapter03LightTunnel(
            runID: runID
        )

        let emitter = Entity()
        emitter.name = "Chapter03AngelLightAudioEmitter"
        emitter.position = .zero
        emitter.components.set(SpatialAudioComponent())
        bundle.angel.root.addChild(emitter)
        var preparedHeavenEmbers: Chapter03HeavenPortalEmberController?
        do {
            let controller = try Chapter03HeavenPortalEmberController(
                perimeterLocalPoints: bundle.portalGeometry.boundaryPoints
            )
            bundle.portalTravelRoot.addChild(controller.rootEntity)
            preparedHeavenEmbers = controller
        } catch {
            // The visual accent may never delay or stop the authored chapter.
            Chapter03HeavenPortalEmberDiagnostics.cueUnavailable(error)
        }
        worldAnchor.addChild(bundle.root)

        let preparedProjection: MindEyeAngelProjectionController?
        do {
            preparedProjection = try await MindEyeAngelProjectionController.prepare(
                runID: runID,
                subjectRoot: bundle.angel.root
            )
        } catch {
            preparedProjection = nil
            print(
                "[MindEyeProjection] Angel unavailable; imported material retained " +
                    "runID=\(runID.uuidString) error=\(error.localizedDescription)"
            )
        }

        self.runID = runID
        sceneBundle = bundle
        root = bundle.root
        portalTravelRoot = bundle.portalTravelRoot
        portalWorld = bundle.portalWorld
        portalAperture = bundle.runtimePortalAperture
        portalDome = bundle.portalDome
        portalIBLEntity = bundle.iblEntity
        angel = bundle.angel
        heavenPortalEmbers = preparedHeavenEmbers
        self.angelVisemeTrack = angelVisemeTrack
        angelPerformance = Chapter03AngelPerformanceCoordinator()
        angelProjection = preparedProjection
        if preparedProjection != nil {
            bundle.angel.setProjectionReadiness(
                Chapter03AngelProjectionReadiness(
                    cameraReady: true,
                    materialReady: true,
                    textureReady: true,
                    maskReady: true,
                    blendShapeReady: true
                )
            )
        } else {
            bundle.angel.setProjectionReadiness(.unavailable)
        }
        angelAudioEmitter = emitter
        lastLoggedDistanceBucket = nil

        print(
            """
            [Chapter03LightTunnel] circular portal instantiated
              runID: \(runID.uuidString)
              diameterMeters: \(definition.portalDiameterMeters)
              startDistanceMeters: \(definition.startDistanceMeters)
              endDistanceMeters: \(definition.endDistanceMeters)
              approachDurationSeconds: \(definition.approachDurationSeconds)
              postApproachTravelMeters: \(definition.postApproachTravelMeters)
              angelInsideOffsetMeters: \(definition.angelInsideOffsetMeters)
              rectangularFrames: 0
              whiteWash: 0
              followsHeadset: false
            """
        )
    }

    func update(
        runID: UUID,
        mediaTimeSeconds: Double,
        durationSeconds: Double,
        definition: Chapter03LightTunnelDefinition
    ) throws {
        guard self.runID == runID, let portalTravelRoot else {
            throw Chapter03Error.staleRun
        }
        let visual = definition.visual
        let boundedTime = max(0, min(mediaTimeSeconds, durationSeconds))
        let approachProgress = Float(
            min(1, boundedTime / visual.approachDurationSeconds)
        )
        let initialDistance = visual.startDistanceMeters +
            (visual.endDistanceMeters - visual.startDistanceMeters) *
            approachProgress
        let remainingDuration = max(
            0,
            durationSeconds - visual.approachDurationSeconds
        )
        let postApproachProgress: Float
        if remainingDuration > 0, boundedTime > visual.approachDurationSeconds {
            postApproachProgress = Float(
                min(
                    1,
                    (boundedTime - visual.approachDurationSeconds) /
                        remainingDuration
                )
            )
        } else {
            postApproachProgress = 0
        }
        let distance = initialDistance -
            visual.postApproachTravelMeters * postApproachProgress
        portalTravelRoot.position = SIMD3<Float>(0, 0, -distance)

        let distanceBucket = Int(distance.rounded(.down))
        if distanceBucket != lastLoggedDistanceBucket,
           distanceBucket % 5 == 0 || postApproachProgress >= 1 {
            lastLoggedDistanceBucket = distanceBucket
            print(
                "[Chapter03LightTunnel] circular portal approach " +
                    "mediaTime=\(String(format: "%.2f", boundedTime)) " +
                    "approachProgress=\(String(format: "%.3f", approachProgress)) " +
                    "postApproachProgress=\(String(format: "%.3f", postApproachProgress)) " +
                    "distanceMeters=\(String(format: "%.3f", distance))"
            )
        }
    }

    func updateFrame(deltaTime: TimeInterval) {
        guard runID != nil else { return }
        angel?.updateFloatMotion(deltaTime: deltaTime)
        angelProjection?.update(deltaTime: deltaTime)
        angelPerformance?.update(deltaTime: deltaTime)
        heavenPortalEmbers?.update(deltaTime: deltaTime)
    }

    func updateAngelFloatMotion(deltaTime: TimeInterval) {
        updateFrame(deltaTime: deltaTime)
    }

    func beginAngelPrerecordingEmberPerformance(
        runID: UUID,
        start: StorySpatialPrerecordingPlaybackStart
    ) throws {
        guard self.runID == runID, start.runID == runID else {
            throw Chapter03Error.staleRun
        }
        angelPerformance?.begin(
            start: start,
            track: angelVisemeTrack,
            projection: angelProjection,
            blendShape: angel?.blendShapeController,
            embers: heavenPortalEmbers
        )
    }

    func endAngelPrerecordingEmberPerformance(
        runID: UUID,
        playbackID: UUID?
    ) {
        guard self.runID == runID else { return }
        angelPerformance?.end(
            runID: runID,
            playbackID: playbackID
        )
    }

    func fadeOutAndRemove(runID: UUID) async throws {
        guard self.runID == runID else { throw Chapter03Error.staleRun }
        remove(runID: runID, reason: "actualMediaCompleted")
    }

    func remove(runID: UUID?, reason: String) {
        guard let current = self.runID,
              runID == nil || runID == current else { return }

        angelPerformance?.teardown(reason: reason)
        angelPerformance = nil
        angelProjection?.release(reason: reason)
        angelProjection = nil
        angel?.setProjectionReadiness(.unavailable)
        heavenPortalEmbers?.teardown(reason: reason)
        heavenPortalEmbers = nil
        angelVisemeTrack = nil
        sceneBundle?.release(reason: reason)
        sceneBundle = nil
        angel = nil
        root = nil
        portalTravelRoot = nil
        portalWorld = nil
        portalAperture = nil
        portalDome = nil
        portalIBLEntity = nil
        angelAudioEmitter = nil
        lastLoggedDistanceBucket = nil
        self.runID = nil
        cinematicWorld.releaseChapter03LightTunnel(runID: current)
        print(
            "[Chapter03LightTunnel] circular portal released " +
                "runID=\(current.uuidString) reason=\(reason)"
        )
    }

    var modelEntityCount: Int {
        (portalAperture == nil ? 0 : 1) +
            (portalDome == nil ? 0 : 1)
    }

    var rootEntityCount: Int { root == nil ? 0 : 1 }
    var angelResourceCount: Int { angel == nil ? 0 : 1 }
    var heavenEmberRootCount: Int { heavenPortalEmbers == nil ? 0 : 1 }
    var activeHeavenEmberCount: Int { heavenPortalEmbers?.activeEmberCount ?? 0 }
}
