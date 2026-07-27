import Foundation
import RealityKit
import simd
import UIKit

@MainActor
struct PortalHDRIDomeEntityFactory {
    func makeDome(
        texture: TextureResource,
        atmosphereID: String,
        visibleExposure: Float,
        providerType: String,
        opening: StoryPortalOpening?,
        ownerID: UUID,
        placement: PortalHDRIDomePlacement,
        surfaceContract: PortalHDRIDomeSurfaceContract
    ) throws -> ModelEntity {
        try placement.validate(usage: providerType)
        PortalHDRIDomeComponents.registerIfNeeded()

        let dome: ModelEntity
        switch surfaceContract {
        case .storyInteriorOnly:
            guard let opening else {
                throw PortalHDRIDomeError.invalidStoryRuntime(
                    "Story dome requires an explicit door or window opening."
                )
            }
            guard placement == .storyOpening else {
                throw PortalHDRIDomeError.invalidStoryRuntime(
                    "\(providerType) must use PortalHDRIDomePlacement.storyOpening."
                )
            }
            dome = makeStoryDome(
                texture: texture,
                atmosphereID: atmosphereID,
                visibleExposure: visibleExposure,
                opening: opening,
                placement: placement
            )

        case .legacyPreserveCurrentBehavior:
            guard opening == nil else {
                throw PortalHDRIDomeError.invalidStoryRuntime(
                    "Legacy dome cannot claim a Story opening."
                )
            }
            dome = makeLegacyDome(
                texture: texture,
                atmosphereID: atmosphereID,
                visibleExposure: visibleExposure,
                placement: placement
            )
        }

        dome.components.set(
            PortalHDRIDomeRuntimeComponent(
                opening: opening,
                providerType: providerType,
                atmosphereID: atmosphereID,
                radiusMeters: placement.radiusMeters,
                centerOffsetZ: placement.centerOffsetZ,
                nearestShellDistanceMeters: placement.nearestShellDistanceMeters,
                meshWinding: surfaceContract.meshWinding,
                surfaceContract: surfaceContract,
                ownerID: ownerID
            )
        )

        if surfaceContract == .storyInteriorOnly {
            try assertStoryContract(
                dome: dome,
                placement: placement,
                providerType: providerType
            )
        }

        return dome
    }

    private func makeStoryDome(
        texture: TextureResource,
        atmosphereID: String,
        visibleExposure: Float,
        opening: StoryPortalOpening,
        placement: PortalHDRIDomePlacement
    ) -> ModelEntity {
        var material = makeMaterial(
            texture: texture,
            visibleExposure: visibleExposure
        )
        material.faceCulling = .front

        let dome = ModelEntity(
            mesh: .generateSphere(radius: placement.radiusMeters),
            materials: [material]
        )
        dome.name = "StoryPortalDome_\(opening.rawValue)_\(atmosphereID)"
        dome.position = SIMD3<Float>(0, 0, placement.centerOffsetZ)
        dome.scale = SIMD3<Float>(repeating: 1)
        dome.orientation = simd_quatf(
            angle: PortalHDRIPanoramaOrientation.story.baseYawRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )
        return dome
    }

    private func makeLegacyDome(
        texture: TextureResource,
        atmosphereID: String,
        visibleExposure: Float,
        placement: PortalHDRIDomePlacement
    ) -> ModelEntity {
        var material = makeMaterial(
            texture: texture,
            visibleExposure: visibleExposure
        )

        // Preserve the existing non-Story surface behavior exactly.
        material.faceCulling = .back

        let dome = ModelEntity(
            mesh: .generateSphere(radius: placement.radiusMeters),
            materials: [material]
        )
        dome.name = "PortalHDRIDome_\(atmosphereID)"
        dome.position = SIMD3<Float>(0, 0, placement.centerOffsetZ)
        dome.scale = SIMD3<Float>(-1, 1, 1)
        dome.orientation = simd_quatf(
            angle: PortalHDRIPanoramaOrientation.legacy.baseYawRadians,
            axis: SIMD3<Float>(0, 1, 0)
        )
        return dome
    }

    private func makeMaterial(
        texture: TextureResource,
        visibleExposure: Float
    ) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(
                red: CGFloat(visibleExposure),
                green: CGFloat(visibleExposure),
                blue: CGFloat(visibleExposure),
                alpha: 1.0
            ),
            texture: .init(texture)
        )
        return material
    }

    private func assertStoryContract(
        dome: ModelEntity,
        placement: PortalHDRIDomePlacement,
        providerType: String
    ) throws {
        let tolerance: Float = 0.0001
        guard abs(dome.position.x) <= tolerance,
              abs(dome.position.y) <= tolerance,
              abs(dome.position.z - placement.centerOffsetZ) <= tolerance else {
            throw PortalHDRIDomeError.invalidStoryRuntime(
                "\(providerType) dome has the wrong local center."
            )
        }

        guard simd_length(dome.scale - SIMD3<Float>(repeating: 1)) <= tolerance else {
            throw PortalHDRIDomeError.invalidStoryRuntime(
                "\(providerType) dome must use positive unit scale."
            )
        }

        guard simd_determinant(dome.transform.matrix) > 0 else {
            throw PortalHDRIDomeError.invalidStoryRuntime(
                "\(providerType) dome has a negative transform determinant."
            )
        }

        guard let model = dome.components[ModelComponent.self] else {
            throw PortalHDRIDomeError.missingModelComponent
        }
        guard let material = model.materials.first as? UnlitMaterial else {
            throw PortalHDRIDomeError.missingUnlitMaterial
        }
        guard material.faceCulling == .front else {
            throw PortalHDRIDomeError.invalidStoryRuntime(
                "\(providerType) must use front-face culling."
            )
        }
    }
}

@MainActor
enum PortalHDRIDomeRuntimeDiagnostics {
    static func storyDomes(
        in root: Entity,
        opening: StoryPortalOpening? = nil
    ) -> [ModelEntity] {
        var result: [ModelEntity] = []
        collectStoryDomes(in: root, opening: opening, result: &result)
        return result
    }

    static func validateExistingOwner(
        in root: Entity,
        opening: StoryPortalOpening,
        ownerID: UUID
    ) throws {
        let existing = storyDomes(in: root, opening: opening)
        guard existing.count <= 1 else {
            let names = existing.map(\.name).joined(separator: ", ")
            throw PortalHDRIDomeError.invalidStoryRuntime(
                "Multiple \(opening.rawValue) Story domes exist: \(names)"
            )
        }

        if let dome = existing.first,
           let metadata = dome.components[PortalHDRIDomeRuntimeComponent.self],
           metadata.ownerID != ownerID {
            throw PortalHDRIDomeError.invalidStoryRuntime(
                "\(opening.rawValue) Story dome owner changed from \(metadata.ownerID) to \(ownerID)."
            )
        }
    }

    static func logRemoval(
        from root: Entity,
        reason: String
    ) {
        for dome in storyDomes(in: root) {
            guard let metadata = dome.components[PortalHDRIDomeRuntimeComponent.self] else {
                continue
            }
            print("""
            [StoryPortalDome] removed
              opening: \(metadata.opening?.rawValue ?? "none")
              providerType: \(metadata.providerType)
              entityName: \(dome.name)
              atmosphere: \(metadata.atmosphereID)
              ownerID: \(metadata.ownerID.uuidString)
              reason: \(reason)
            """)
        }
    }

    static func logInstalled(_ dome: ModelEntity) throws {
        guard let metadata = dome.components[PortalHDRIDomeRuntimeComponent.self],
              metadata.surfaceContract == .storyInteriorOnly else {
            return
        }
        guard let model = dome.components[ModelComponent.self],
              let material = model.materials.first as? UnlitMaterial else {
            throw PortalHDRIDomeError.missingUnlitMaterial
        }

        let worldMatrix = dome.transformMatrix(relativeTo: nil)
        let worldCenter = worldMatrix.columns.3
        print("""
        [StoryPortalDome] installed
          opening: \(metadata.opening?.rawValue ?? "none")
          providerType: \(metadata.providerType)
          entityName: \(dome.name)
          atmosphere: \(metadata.atmosphereID)
          radiusMeters: \(metadata.radiusMeters)
          portalLocalCenter: [\(dome.position.x), \(dome.position.y), \(dome.position.z)]
          worldCenter: [\(worldCenter.x), \(worldCenter.y), \(worldCenter.z)]
          nearestShellDistanceMeters: \(metadata.nearestShellDistanceMeters)
          scale: [\(dome.scale.x), \(dome.scale.y), \(dome.scale.z)]
          transformDeterminantSign: \(simd_determinant(dome.transform.matrix) > 0 ? "positive" : "negative")
          meshWinding: \(metadata.meshWinding.rawValue)
          faceCulling: \(String(describing: material.faceCulling))
          exteriorVisible: false
          ownerID: \(metadata.ownerID.uuidString)
        """)
    }

    private static func collectStoryDomes(
        in entity: Entity,
        opening: StoryPortalOpening?,
        result: inout [ModelEntity]
    ) {
        if let dome = entity as? ModelEntity,
           let metadata = dome.components[PortalHDRIDomeRuntimeComponent.self],
           metadata.surfaceContract == .storyInteriorOnly,
           opening == nil || metadata.opening == opening {
            result.append(dome)
        }

        for child in entity.children {
            collectStoryDomes(in: child, opening: opening, result: &result)
        }
    }
}
