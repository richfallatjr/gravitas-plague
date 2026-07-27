import CoreGraphics
import Foundation
import ImageIO
import RealityKit

struct HDRIDomePortalContentProvider: PortalContentProvider {
    static let providerID = "hdriDome"

    var providerID: String { Self.providerID }

    let atmosphere: PortalHDRIAtmosphere
    let placement: PortalHDRIDomePlacement
    let surfaceContract: PortalHDRIDomeSurfaceContract
    let opening: StoryPortalOpening?
    let providerType: String
    let ownerID: UUID

    init(
        atmosphere: PortalHDRIAtmosphere,
        placement: PortalHDRIDomePlacement,
        surfaceContract: PortalHDRIDomeSurfaceContract,
        opening: StoryPortalOpening?,
        providerType: String,
        ownerID: UUID
    ) {
        self.atmosphere = atmosphere
        self.placement = placement
        self.surfaceContract = surfaceContract
        self.opening = opening
        self.providerType = providerType
        self.ownerID = ownerID
    }

    @MainActor
    static func clearSharedResourceCache(
        reason: String
    ) {
        PortalHDRIResourceCache.entry = nil
        PortalHDRIResourceCache.ownerKeys.removeAll(keepingCapacity: false)
        print("[PortalHDRI] shared resource cache cleared reason=\(reason)")
    }

    @MainActor
    static func releaseSharedResourceLease(
        portalWorld: Entity,
        reason: String
    ) {
        PortalHDRIResourceCache.ownerKeys.remove(
            ObjectIdentifier(portalWorld)
        )
        let remainingOwnerCount = PortalHDRIResourceCache.ownerKeys.count
        if remainingOwnerCount == 0 {
            PortalHDRIResourceCache.entry = nil
        }
        print("""
        [PortalHDRI] shared resource lease released
          reason: \(reason)
          remainingOwnerCount: \(remainingOwnerCount)
          cacheCleared: \(remainingOwnerCount == 0)
        """)
    }

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity,
        context: PortalContentContext
    ) async throws {
        if let opening {
            try PortalHDRIDomeRuntimeDiagnostics.validateExistingOwner(
                in: portalWorld,
                opening: opening,
                ownerID: ownerID
            )
        }
        PortalHDRIDomeRuntimeDiagnostics.logRemoval(
            from: portalWorld,
            reason: "providerReplacement"
        )
        portalWorld.children.removeAll()
        portalWorld.components.set(WorldComponent())
        PlagueNativeBloomInstaller.installStrictBloom(
            on: portalWorld
        )

        let resources = try loadEXRResources(atmosphere: atmosphere)
        PortalHDRIResourceCache.ownerKeys.insert(
            ObjectIdentifier(portalWorld)
        )

        let dome = try PortalHDRIDomeEntityFactory().makeDome(
            texture: resources.visibleTexture,
            atmosphereID: atmosphere.rawValue,
            visibleExposure: atmosphere.visibleExposure,
            providerType: providerType,
            opening: opening,
            ownerID: ownerID,
            placement: placement,
            surfaceContract: surfaceContract
        )

        portalWorld.addChild(dome)
        try PortalHDRIDomeRuntimeDiagnostics.logInstalled(dome)

        if let opening {
            let installed = PortalHDRIDomeRuntimeDiagnostics.storyDomes(
                in: portalWorld,
                opening: opening
            )
            guard installed.count == 1 else {
                throw PortalHDRIDomeError.invalidStoryRuntime(
                    "Expected exactly one \(opening.rawValue) Story dome after installation; found \(installed.count)."
                )
            }
        }

        if context.groundDiscEnabled {
            let ground = try PortalProjectedGroundDiscFactory.makeGroundDisc(
                texture: resources.visibleTexture,
                config: .init(
                    floorY: context.floorY + 0.004,
                    centerZ: context.groundDiscCenterZ,
                    radius: context.groundDiscRadius,
                    exposure: atmosphere.visibleExposure
                )
            )

            portalWorld.addChild(ground)
        }

        let iblEntity = makeIBLEntity(
            environment: resources.environment,
            resourceName: resources.name,
            atmosphere: atmosphere
        )

        portalWorld.addChild(iblEntity)

        attachIBLReceiversRecursively(
            under: portalWorld,
            iblEntity: iblEntity
        )

        print(
            """
            [PortalHDRI] portal world populated
              atmosphere: \(atmosphere.rawValue)
              exr: \(atmosphere.exrResourceName).exr
              dome: true
              domeRadius: \(placement.radiusMeters)
              domeCenterOffsetZ: \(placement.centerOffsetZ)
              nearestDomeShellDistance: \(placement.nearestShellDistanceMeters)
              surfaceContract: \(surfaceContract.rawValue)
              opening: \(opening?.rawValue ?? "none")
              ownerID: \(ownerID.uuidString)
              projectedGroundDisc: \(context.groundDiscEnabled)
              floorY: \(context.floorY)
              groundRadius: \(context.groundDiscRadius)
              ibl: true
              provider: \(Self.providerID)
            """
        )
    }
}

private struct LoadedPortalEXRResources {
    let name: String
    let visibleTexture: TextureResource
    let environment: EnvironmentResource
}

@MainActor
private enum PortalHDRIResourceCache {
    struct Entry {
        let key: String
        let resources: LoadedPortalEXRResources
    }

    static var entry: Entry?
    static var ownerKeys = Set<ObjectIdentifier>()
}

private extension HDRIDomePortalContentProvider {
    @MainActor
    func loadEXRResources(
        atmosphere: PortalHDRIAtmosphere
    ) throws -> LoadedPortalEXRResources {
        guard let url = Bundle.main.url(
            forResource: atmosphere.exrResourceName,
            withExtension: atmosphere.exrExtension
        ) else {
            throw NSError(
                domain: "PortalHDRI",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing portal HDRI EXR \(atmosphere.exrResourceName).exr"
                ]
            )
        }

        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let fileSizeBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modifiedEpochSeconds = Int(
            (attributes?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
        )
        let resourceStamp = "\(fileSizeBytes)_\(modifiedEpochSeconds)"
        let visibleTextureName =
            "\(atmosphere.exrResourceName)_\(resourceStamp)_portal_visible_texture"
        let environmentName =
            "\(atmosphere.exrResourceName)_\(resourceStamp)_portal_ibl"
        let cacheKey = "\(atmosphere.rawValue)|\(resourceStamp)"

        if let cached = PortalHDRIResourceCache.entry,
           cached.key == cacheKey {
            print(
                """
                [PortalHDRI] shared resource cache hit
                  atmosphere: \(atmosphere.rawValue)
                  resourceStamp: \(resourceStamp)
                  exrDecodeAvoided: true
                  textureRecreationAvoided: true
                  environmentRecreationAvoided: true
                """
            )
            return cached.resources
        }

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            throw NSError(
                domain: "PortalHDRI",
                code: 405,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CGImageSourceCreateWithURL failed for \(url.lastPathComponent)"
                ]
            )
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else {
            throw NSError(
                domain: "PortalHDRI",
                code: 406,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CGImageSourceCreateImageAtIndex failed for \(url.lastPathComponent)"
                ]
            )
        }

        print(
            """
            [PortalHDRI] EXR loaded
              file: \(url.lastPathComponent)
              url: \(url.path)
              fileSizeBytes: \(fileSizeBytes)
              modifiedEpochSeconds: \(modifiedEpochSeconds)
              resourceStamp: \(resourceStamp)
              width: \(cgImage.width)
              height: \(cgImage.height)
            """
        )

        let texture = try TextureResource(
            image: cgImage,
            withName: visibleTextureName,
            options: .init(semantic: .color)
        )

        let environment = try EnvironmentResource(
            equirectangular: cgImage,
            withName: environmentName
        )

        let resources = LoadedPortalEXRResources(
            name: atmosphere.exrResourceName,
            visibleTexture: texture,
            environment: environment
        )
        PortalHDRIResourceCache.entry = .init(
            key: cacheKey,
            resources: resources
        )
        print(
            """
            [PortalHDRI] shared resource cache populated
              atmosphere: \(atmosphere.rawValue)
              resourceStamp: \(resourceStamp)
              retainedCGImage: false
            """
        )
        return resources
    }

    @MainActor
    func makeIBLEntity(
        environment: EnvironmentResource,
        resourceName: String,
        atmosphere: PortalHDRIAtmosphere
    ) -> Entity {
        let iblEntity = Entity()
        iblEntity.name = "PortalIBL_\(resourceName)"

        var ibl = ImageBasedLightComponent(
            source: .single(environment)
        )

        ibl.intensityExponent = atmosphere.iblIntensityExponent

        iblEntity.components.set(ibl)

        print(
            """
            [PortalHDRI] IBL entity created from same EXR
              atmosphere: \(atmosphere.rawValue)
              resource: \(resourceName).exr
              intensityExponent: \(atmosphere.iblIntensityExponent)
            """
        )

        return iblEntity
    }

    @MainActor
    func attachIBLReceiversRecursively(
        under root: Entity,
        iblEntity: Entity
    ) {
        root.components.set(
            ImageBasedLightReceiverComponent(
                imageBasedLight: iblEntity
            )
        )

        for child in root.children {
            attachIBLReceiversRecursively(
                under: child,
                iblEntity: iblEntity
            )
        }
    }
}
