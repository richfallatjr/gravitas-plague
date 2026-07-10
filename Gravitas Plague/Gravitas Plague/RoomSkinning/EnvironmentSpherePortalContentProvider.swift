import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd
import UIKit

struct HDRIDomePortalContentProvider: PortalContentProvider {
    static let providerID = "hdriDome"

    var providerID: String { Self.providerID }

    let atmosphere: PortalHDRIAtmosphere
    let domeCenterOffsetZ: Float

    init(
        atmosphere: PortalHDRIAtmosphere,
        domeCenterOffsetZ: Float = 0.0
    ) {
        self.atmosphere = atmosphere
        self.domeCenterOffsetZ = domeCenterOffsetZ
    }

    @MainActor
    static func clearSharedResourceCache(
        reason: String
    ) {
        PortalHDRIResourceCache.entry = nil
        print("[PortalHDRI] shared resource cache cleared reason=\(reason)")
    }

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity,
        context: PortalContentContext
    ) async throws {
        portalWorld.children.removeAll()
        portalWorld.components.set(WorldComponent())
        PlagueNativeBloomInstaller.installStrictBloom(
            on: portalWorld
        )

        let resources = try loadEXRResources(atmosphere: atmosphere)

        let dome = try makeInsideFacingHDRIDome(
            texture: resources.visibleTexture,
            resourceName: resources.name,
            atmosphere: atmosphere,
            centerOffsetZ: domeCenterOffsetZ
        )

        portalWorld.addChild(dome)

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
              domeCenterOffsetZ: \(domeCenterOffsetZ)
              projectedGroundDisc: \(context.groundDiscEnabled)
              floorY: \(context.floorY)
              groundRadius: \(context.groundDiscRadius)
              ibl: true
              provider: \(Self.providerID)
            """
        )
    }
}

private enum PortalHDRIDomeOrientation {
    static let yRotationDegrees: Float = 90.0

    static var yRotationRadians: Float {
        yRotationDegrees * .pi / 180.0
    }
}

enum PortalHDRIDomePlacementTuning {
    static let radiusMeters: Float = 12.0
    static let storyOpeningCenterOffsetZ: Float = -9.0
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
    func makeInsideFacingHDRIDome(
        texture: TextureResource,
        resourceName: String,
        atmosphere: PortalHDRIAtmosphere,
        centerOffsetZ: Float
    ) throws -> ModelEntity {
        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(
                red: CGFloat(atmosphere.visibleExposure),
                green: CGFloat(atmosphere.visibleExposure),
                blue: CGFloat(atmosphere.visibleExposure),
                alpha: 1.0
            ),
            texture: .init(texture)
        )
        material.faceCulling = .none

        let radius = PortalHDRIDomePlacementTuning.radiusMeters

        let dome = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [material]
        )

        dome.name = "PortalHDRIDome_\(resourceName)"
        dome.position.z = centerOffsetZ
        dome.scale = SIMD3<Float>(-1, 1, 1)
        dome.orientation = simd_quatf(
            angle: PortalHDRIDomeOrientation.yRotationRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )

        print(
            """
            [PortalHDRI] visible EXR dome created
              atmosphere: \(atmosphere.rawValue)
              radius: \(radius)
              centerOffsetZ: \(centerOffsetZ)
              centerOffsetFractionOfRadius: \(abs(centerOffsetZ) / radius)
              forwardDepthFractionOfDiameter: \((radius - centerOffsetZ) / (radius * 2.0))
              negativeXScale: true
              yRotationDegrees: \(PortalHDRIDomeOrientation.yRotationDegrees)
              faceCulling: none
              unlitMaterial: true
              textureFromEXR: true
              visibleExposure: \(atmosphere.visibleExposure)
            """
        )

        return dome
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
