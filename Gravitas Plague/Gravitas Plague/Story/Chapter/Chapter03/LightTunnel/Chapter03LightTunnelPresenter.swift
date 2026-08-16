import Foundation
import ImageIO
import RealityKit
import simd

@MainActor
final class Chapter03LightTunnelPresenter {
    private struct HeavenResources {
        let texture: TextureResource
        let environment: EnvironmentResource
    }

    private let cinematicWorld: CinematicWorldPresentationCoordinator
    private var runID: UUID?
    private var root: Entity?
    private var portalTravelRoot: Entity?
    private var portalWorld: Entity?
    private var portalAperture: ModelEntity?
    private var portalDome: ModelEntity?
    private var portalIBLEntity: Entity?
    private var angel: Chapter03AngelPortalEntity?
    private(set) var angelAudioEmitter: Entity?
    private var lastLoggedDistanceBucket: Int?

    init(cinematicWorld: CinematicWorldPresentationCoordinator) {
        self.cinematicWorld = cinematicWorld
    }

    func prepare(
        runID: UUID,
        originFromDevice: simd_float4x4,
        definition: Chapter03LightTunnelVisualDefinition
    ) async throws {
        remove(runID: self.runID, reason: "replacement")

        let resources = try loadHeavenResources()
        let angel = try await Chapter03AngelPortalEntity.load(
            insideOffsetMeters: definition.angelInsideOffsetMeters,
            rootYOffsetMeters: definition.angelRootYOffsetMeters
        )
        let worldAnchor = try cinematicWorld.claimChapter03LightTunnel(
            runID: runID
        )

        let root = Entity()
        root.name = "Chapter03LightTunnelRoot"
        root.setTransformMatrix(originFromDevice, relativeTo: nil)

        let portalTravelRoot = Entity()
        portalTravelRoot.name = "Chapter03CircularPortalTravelRoot"
        portalTravelRoot.position = SIMD3<Float>(
            0,
            0,
            -definition.startDistanceMeters
        )

        let portalWorld = Entity()
        portalWorld.name = "Chapter03HeavenPortalWorld"
        portalWorld.components.set(WorldComponent())

        let portalDome = makeInsideFacingDome(
            resources: resources,
            definition: definition
        )
        portalWorld.addChild(portalDome)

        let iblEntity = makeIBLEntity(environment: resources.environment)
        portalWorld.addChild(iblEntity)
        attachIBLReceiverRecursively(
            to: angel.root,
            iblEntity: iblEntity
        )
        portalWorld.addChild(angel.root)

        let emitter = Entity()
        emitter.name = "Chapter03AngelLightAudioEmitter"
        emitter.position = angel.root.position
        portalWorld.addChild(emitter)

        let aperture = try makeCircularPortalAperture(
            diameterMeters: definition.portalDiameterMeters,
            targetWorld: portalWorld
        )

        portalTravelRoot.addChild(portalWorld)
        portalTravelRoot.addChild(aperture)
        root.addChild(portalTravelRoot)
        worldAnchor.addChild(root)

        self.runID = runID
        self.root = root
        self.portalTravelRoot = portalTravelRoot
        self.portalWorld = portalWorld
        self.portalAperture = aperture
        self.portalDome = portalDome
        portalIBLEntity = iblEntity
        self.angel = angel
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
        let progress = Float(
            min(1, boundedTime / visual.approachDurationSeconds)
        )
        let distance = visual.startDistanceMeters +
            (visual.endDistanceMeters - visual.startDistanceMeters) * progress
        portalTravelRoot.position = SIMD3<Float>(0, 0, -distance)

        let distanceBucket = Int(distance.rounded(.down))
        if distanceBucket != lastLoggedDistanceBucket,
           distanceBucket % 5 == 0 || progress >= 1 {
            lastLoggedDistanceBucket = distanceBucket
            print(
                "[Chapter03LightTunnel] circular portal approach " +
                    "mediaTime=\(String(format: "%.2f", boundedTime)) " +
                    "progress=\(String(format: "%.3f", progress)) " +
                    "distanceMeters=\(String(format: "%.3f", distance))"
            )
        }
    }

    func fadeOutAndRemove(runID: UUID) async throws {
        guard self.runID == runID else { throw Chapter03Error.staleRun }
        remove(runID: runID, reason: "actualMediaCompleted")
    }

    func remove(runID: UUID?, reason: String) {
        guard let current = self.runID,
              runID == nil || runID == current else { return }

        angel?.release(reason: reason)
        angel = nil
        root?.removeFromParent()
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

    private func loadHeavenResources() throws -> HeavenResources {
        guard let url = Bundle.main.url(
            forResource: "heaven-sunrise",
            withExtension: "exr"
        ) else {
            throw Chapter03Error.heavenResourceMissing("heaven-sunrise.exr")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Chapter03Error.heavenResourceInvalid("heaven-sunrise.exr")
        }

        let texture = try TextureResource(
            image: image,
            withName: "chapter03_heaven_sunrise_visible",
            options: .init(semantic: .color)
        )
        let environment = try EnvironmentResource(
            equirectangular: image,
            options: .init(
                samplingQuality: .fast,
                specularCubeDimension: nil,
                compression: .default
            )
        )
        print(
            "[Chapter03LightTunnel] heaven EXR loaded " +
                "file=\(url.lastPathComponent) width=\(image.width) height=\(image.height)"
        )
        return HeavenResources(texture: texture, environment: environment)
    }

    private func makeCircularPortalAperture(
        diameterMeters: Float,
        targetWorld: Entity
    ) throws -> ModelEntity {
        let segments = 128
        let radius = diameterMeters * 0.5
        var positions = [SIMD3<Float>(0, 0, 0)]
        positions.reserveCapacity(segments + 1)
        for index in 0..<segments {
            let angle = 2 * Float.pi * Float(index) / Float(segments)
            positions.append(
                SIMD3<Float>(radius * cos(angle), radius * sin(angle), 0)
            )
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(segments * 3)
        for index in 0..<segments {
            let next = (index + 1) % segments
            indices.append(contentsOf: [
                0,
                UInt32(index + 1),
                UInt32(next + 1)
            ])
        }

        var descriptor = MeshDescriptor(name: "Chapter03CircularPortalDisc")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        let mesh = try MeshResource.generate(from: [descriptor])
        let aperture = ModelEntity(
            mesh: mesh,
            materials: [PortalMaterial()]
        )
        aperture.name = "Chapter03CircularPortalAperture"
        aperture.components.set(
            PortalComponent(
                target: targetWorld,
                clippingMode: .plane(.positiveZ),
                crossingMode: .plane(.positiveZ)
            )
        )
        return aperture
    }

    private func makeInsideFacingDome(
        resources: HeavenResources,
        definition: Chapter03LightTunnelVisualDefinition
    ) -> ModelEntity {
        var material = UnlitMaterial(texture: resources.texture)
        material.faceCulling = .front
        let dome = ModelEntity(
            mesh: .generateSphere(radius: definition.domeRadiusMeters),
            materials: [material]
        )
        dome.name = "Chapter03HeavenSunriseDome"
        dome.position.z = definition.domeCenterOffsetZMeters
        dome.scale = SIMD3<Float>(repeating: 1)
        return dome
    }

    private func makeIBLEntity(environment: EnvironmentResource) -> Entity {
        let entity = Entity()
        entity.name = "Chapter03HeavenIBL"
        var ibl = ImageBasedLightComponent(source: .single(environment))
        ibl.intensityExponent = 0.5
        entity.components.set(ibl)
        return entity
    }

    private func attachIBLReceiverRecursively(
        to entity: Entity,
        iblEntity: Entity
    ) {
        entity.components.set(
            ImageBasedLightReceiverComponent(imageBasedLight: iblEntity)
        )
        for child in entity.children {
            attachIBLReceiverRecursively(to: child, iblEntity: iblEntity)
        }
    }
}
