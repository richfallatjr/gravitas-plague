import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd
import UIKit

enum HordePortalAssetValidator {
    static func validate() {
        if let url = HordeHellscapeEXRLocator.url() {
            print(
                """
                [HordePortal] found hellscape backdrop
                  file: \(url.lastPathComponent)
                  url: \(url.path)
                """
            )
        } else {
            print(
                """
                [HordePortal] ERROR missing hellscape backdrop
                  file: hellscape_01.exr
                """
            )
        }
    }
}

private enum HordeHellscapeEXRLocator {
    static func url() -> URL? {
        Bundle.main.url(
            forResource: "hellscape_01",
            withExtension: "exr"
        )
    }
}

private struct LoadedHordeHellscapeResources {
    let visibleTexture: TextureResource
    let environment: EnvironmentResource
}

struct HordeHellscapePortalContentProvider: PortalContentProvider {
    static let providerID = "hordeHellscapeEXR"

    var providerID: String { Self.providerID }

    @MainActor
    func populatePortalWorld(
        portalWorld: Entity,
        context: PortalContentContext
    ) async throws {
        portalWorld.children.removeAll()
        portalWorld.components.set(WorldComponent())

        let resources = try loadHellscapeResources()

        let dome = try makeInsideFacingDome(
            texture: resources.visibleTexture
        )

        portalWorld.addChild(dome)

        if context.groundDiscEnabled {
            let ground = try PortalProjectedGroundDiscFactory.makeGroundDisc(
                texture: resources.visibleTexture,
                config: .init(
                    floorY: context.floorY + 0.004,
                    centerZ: context.groundDiscCenterZ,
                    radius: context.groundDiscRadius,
                    exposure: 1.0
                )
            )

            portalWorld.addChild(ground)
        }

        let ibl = makeIBLEntity(
            environment: resources.environment
        )

        portalWorld.addChild(ibl)

        attachIBLReceiversRecursively(
            root: portalWorld,
            iblEntity: ibl
        )

        print(
            """
            [HordePortal] hellscape portal world populated
              backdrop: hellscape_01.exr
              visibleDome: true
              projectedGroundDisc: \(context.groundDiscEnabled)
              floorY: \(context.floorY)
              groundRadius: \(context.groundDiscRadius)
              ibl: true
            """
        )
    }
}

private extension HordeHellscapePortalContentProvider {
    @MainActor
    func loadHellscapeResources() throws -> LoadedHordeHellscapeResources {
        guard let url = HordeHellscapeEXRLocator.url() else {
            throw NSError(
                domain: "HordePortal",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing hellscape_01.exr"
                ]
            )
        }

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            throw NSError(
                domain: "HordePortal",
                code: 405,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CGImageSourceCreateWithURL failed for \(url.lastPathComponent)"
                ]
            )
        }

        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else {
            throw NSError(
                domain: "HordePortal",
                code: 406,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CGImageSourceCreateImageAtIndex failed for \(url.lastPathComponent)"
                ]
            )
        }

        print(
            """
            [HordePortal] hellscape EXR loaded
              width: \(image.width)
              height: \(image.height)
            """
        )

        let texture = try TextureResource(
            image: image,
            withName: "hellscape_01_portal_visible_texture",
            options: .init(semantic: .color)
        )

        let environment = try EnvironmentResource(
            equirectangular: image,
            withName: "hellscape_01_portal_ibl"
        )

        return LoadedHordeHellscapeResources(
            visibleTexture: texture,
            environment: environment
        )
    }

    @MainActor
    func makeInsideFacingDome(
        texture: TextureResource
    ) throws -> ModelEntity {
        var material = UnlitMaterial(texture: texture)
        material.faceCulling = .none

        let dome = ModelEntity(
            mesh: .generateSphere(radius: 12.0),
            materials: [material]
        )

        dome.name = "HordeHellscapeVisibleDome"
        dome.scale = SIMD3<Float>(-1, 1, 1)
        dome.orientation = simd_quatf(
            angle: .pi / 2,
            axis: SIMD3<Float>(0, 1, 0)
        )

        return dome
    }

    @MainActor
    func makeIBLEntity(
        environment: EnvironmentResource
    ) -> Entity {
        let entity = Entity()
        entity.name = "HordeHellscapeIBL"

        var ibl = ImageBasedLightComponent(
            source: .single(environment)
        )
        ibl.intensityExponent = 0.72

        entity.components.set(ibl)

        return entity
    }

    @MainActor
    func attachIBLReceiversRecursively(
        root: Entity,
        iblEntity: Entity
    ) {
        root.components.set(
            ImageBasedLightReceiverComponent(
                imageBasedLight: iblEntity
            )
        )

        for child in root.children {
            attachIBLReceiversRecursively(
                root: child,
                iblEntity: iblEntity
            )
        }
    }
}
