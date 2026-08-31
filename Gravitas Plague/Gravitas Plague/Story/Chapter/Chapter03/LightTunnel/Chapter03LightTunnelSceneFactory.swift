import Foundation
import ImageIO
import RealityKit
import simd

@MainActor
struct Chapter03LightTunnelSceneFactory {
    struct HeavenResources {
        let texture: TextureResource
        let environment: EnvironmentResource
    }

    func make(
        runID: UUID,
        definition: Chapter03LightTunnelVisualDefinition,
        originFromDevice: simd_float4x4,
        mode: Chapter03LightTunnelSceneMode,
        resources providedResources: HeavenResources? = nil
    ) async throws -> Chapter03LightTunnelSceneBundle {
        let resources: HeavenResources
        if let providedResources {
            resources = providedResources
        } else {
            resources = try loadHeavenResources()
        }
        let portalGeometry = try Chapter03CircularPortalGeometry.make(
            diameterMeters: definition.portalDiameterMeters
        )
        let angel = try await Chapter03AngelPortalEntity.load(
            insideOffsetMeters: definition.angelInsideOffsetMeters,
            rootYOffsetMeters: definition.angelRootYOffsetMeters
        )
        let root = Entity()
        root.name = "Chapter03LightTunnelRoot"
        root.setTransformMatrix(originFromDevice, relativeTo: nil)

        let portalTravelRoot = Entity()
        portalTravelRoot.name = "Chapter03CircularPortalTravelRoot"
        portalTravelRoot.position = mode == .runtimePortal
            ? SIMD3(0, 0, -definition.startDistanceMeters)
            : .zero

        let portalWorld = Entity()
        portalWorld.name = "Chapter03HeavenPortalWorld"
        if mode == .runtimePortal {
            portalWorld.components.set(WorldComponent())
            PlagueNativeBloomInstaller.installStrictBloom(on: portalWorld)
        }

        let dome = makeInsideFacingDome(resources: resources, definition: definition)
        dome.isEnabled = mode != .projectionAuthoringMask
        portalWorld.addChild(dome)

        let ibl = makeIBLEntity(environment: resources.environment)
        portalWorld.addChild(ibl)
        attachIBLReceiverRecursively(to: angel.root, iblEntity: ibl)
        portalWorld.addChild(angel.root)

        let aperture: ModelEntity?
        if mode == .runtimePortal {
            aperture = try makeCircularPortalAperture(
                geometry: portalGeometry,
                targetWorld: portalWorld
            )
        } else {
            aperture = nil
        }
        portalTravelRoot.addChild(portalWorld)
        if let aperture { portalTravelRoot.addChild(aperture) }
        root.addChild(portalTravelRoot)

        return Chapter03LightTunnelSceneBundle(
            root: root,
            portalTravelRoot: portalTravelRoot,
            portalWorld: portalWorld,
            portalDome: dome,
            iblEntity: ibl,
            environment: resources.environment,
            angel: angel,
            runtimePortalAperture: aperture,
            portalGeometry: portalGeometry,
            definition: definition
        )
    }

    func loadHeavenResources() throws -> HeavenResources {
        guard let url = Bundle.main.url(forResource: "heaven-sunrise", withExtension: "exr") else {
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
            options: .init(samplingQuality: .fast, specularCubeDimension: nil, compression: .default)
        )
        return HeavenResources(texture: texture, environment: environment)
    }

    private func makeCircularPortalAperture(
        geometry: Chapter03CircularPortalGeometry,
        targetWorld: Entity
    ) throws -> ModelEntity {
        var descriptor = MeshDescriptor(name: "Chapter03CircularPortalDisc")
        descriptor.positions = MeshBuffers.Positions(geometry.discPositions)
        descriptor.primitives = .triangles(geometry.triangleIndices)
        let aperture = ModelEntity(
            mesh: try MeshResource.generate(from: [descriptor]),
            materials: [PortalMaterial()]
        )
        aperture.name = "Chapter03CircularPortalAperture"
        aperture.components.set(PortalComponent(
            target: targetWorld,
            clippingMode: .plane(.positiveZ),
            crossingMode: .plane(.positiveZ)
        ))
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
        return dome
    }

    private func makeIBLEntity(environment: EnvironmentResource) -> Entity {
        let entity = Entity()
        entity.name = "Chapter03HeavenIBL"
        var component = ImageBasedLightComponent(source: .single(environment))
        component.intensityExponent = 0.5
        entity.components.set(component)
        return entity
    }

    private func attachIBLReceiverRecursively(to entity: Entity, iblEntity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))
        for child in entity.children {
            attachIBLReceiverRecursively(to: child, iblEntity: iblEntity)
        }
    }
}
