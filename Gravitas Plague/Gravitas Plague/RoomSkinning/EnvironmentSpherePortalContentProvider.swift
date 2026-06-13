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

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity
    ) async throws {
        portalWorld.children.removeAll()
        portalWorld.components.set(WorldComponent())

        let exr = try loadEXR(atmosphere: atmosphere)

        let dome = try makeInsideFacingHDRIDome(
            cgImage: exr.cgImage,
            resourceName: exr.name,
            atmosphere: atmosphere
        )

        let iblEntity = try makeIBLEntity(
            cgImage: exr.cgImage,
            resourceName: exr.name,
            atmosphere: atmosphere
        )

        portalWorld.addChild(dome)
        portalWorld.addChild(iblEntity)

        attachIBLReceiversRecursively(
            under: portalWorld,
            iblEntity: iblEntity
        )

        print(
            """
            [PortalHDRI] portal world populated with EXR dome
              atmosphere: \(atmosphere.rawValue)
              exr: \(atmosphere.exrResourceName).exr
              visibleDome: true
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

private struct LoadedPortalEXR {
    let name: String
    let url: URL
    let cgImage: CGImage
}

private extension HDRIDomePortalContentProvider {
    func loadEXR(
        atmosphere: PortalHDRIAtmosphere
    ) throws -> LoadedPortalEXR {
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
              width: \(cgImage.width)
              height: \(cgImage.height)
            """
        )

        return LoadedPortalEXR(
            name: atmosphere.exrResourceName,
            url: url,
            cgImage: cgImage
        )
    }

    @MainActor
    func makeInsideFacingHDRIDome(
        cgImage: CGImage,
        resourceName: String,
        atmosphere: PortalHDRIAtmosphere
    ) throws -> ModelEntity {
        let texture = try TextureResource(
            image: cgImage,
            withName: "\(resourceName)_portal_visible_dome",
            options: .init(semantic: .color)
        )

        var material = UnlitMaterial(texture: texture)
        material.faceCulling = .none

        let radius: Float = 12.0

        let dome = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [material]
        )

        dome.name = "PortalHDRIVisibleDome_\(atmosphere.rawValue)"
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
        cgImage: CGImage,
        resourceName: String,
        atmosphere: PortalHDRIAtmosphere
    ) throws -> Entity {
        let environment = try EnvironmentResource(
            equirectangular: cgImage,
            withName: "\(resourceName)_portal_ibl"
        )

        let iblEntity = Entity()
        iblEntity.name = "PortalHDRI_IBL_\(atmosphere.rawValue)"

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
