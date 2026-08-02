import RealityKit
import UIKit

@MainActor
enum StoryTitleCardTextFactory {
    private static let baseScale: Float = 0.001
    private static let maximumLineWidth: Float = 1.10
    private static let lineGap: Float = 0.080

    private struct BuiltLine {
        let entity: ModelEntity
        let width: Float
        let height: Float
    }

    static func makeCard(
        _ descriptor: StoryTitleCardDescriptor
    ) -> Entity {
        let root = Entity()
        root.name = "StoryTitleCard.\(descriptor.id.rawValue)"

        let title = makeLine(
            descriptor.title,
            font: PlagueHUDTypography.title(),
            name: "Title"
        )

        if let subtitleText = descriptor.subtitle,
           !subtitleText.trimmingCharacters(
                in: .whitespacesAndNewlines
           ).isEmpty {
            let subtitle = makeLine(
                subtitleText,
                font: PlagueHUDTypography.subtitle(),
                name: "Subtitle"
            )
            let totalHeight = title.height + lineGap + subtitle.height
            title.entity.position.y +=
                totalHeight * 0.5 - title.height * 0.5
            subtitle.entity.position.y +=
                -totalHeight * 0.5 + subtitle.height * 0.5
            root.addChild(title.entity)
            root.addChild(subtitle.entity)
        } else {
            root.addChild(title.entity)
        }

        makeInert(root)
        return root
    }

    private static func makeLine(
        _ text: String,
        font: UIFont,
        name: String
    ) -> BuiltLine {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.0008,
            font: font,
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        let bounds = mesh.bounds
        let unscaledWidth = max(bounds.extents.x, 0.0001)
        let fittedScale = min(
            baseScale,
            maximumLineWidth / unscaledWidth
        )

        var material = UnlitMaterial()
        material.color = .init(tint: PlagueHUDTypography.textColor)
        material.blending = .transparent(opacity: 1.0)

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "StoryTitleCard\(name)"
        entity.scale = SIMD3<Float>(repeating: fittedScale)
        entity.position = SIMD3<Float>(
            -bounds.center.x * fittedScale,
            -bounds.center.y * fittedScale,
            0
        )

        return BuiltLine(
            entity: entity,
            width: bounds.extents.x * fittedScale,
            height: bounds.extents.y * fittedScale
        )
    }

    private static func makeInert(_ entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        for child in entity.children {
            makeInert(child)
        }
    }
}
