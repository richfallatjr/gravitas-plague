import RealityKit
import SwiftUI
import UIKit

@MainActor
final class PlagueHeadTrackedInstructionHUD {
    private var root: Entity?
    private var textEntity: ModelEntity?
    private var backgroundEntity: ModelEntity?
    private var lastText = ""

    private let textScale: Float = 0.001
    private let horizontalPadding: Float = 0.16
    private let verticalPadding: Float = 0.08
    private let rootPosition = SIMD3<Float>(0, -0.32, -1.05)

    private var font: UIFont {
        UIFont(name: "Baskerville-SemiBold", size: 34)
            ?? UIFont(name: "Georgia-Bold", size: 34)
            ?? UIFont.systemFont(ofSize: 34, weight: .semibold)
    }

    func ensure(
        on headAnchor: AnchorEntity
    ) {
        guard root == nil else {
            return
        }

        let rootEntity = Entity()
        rootEntity.name = "PlagueHeadTrackedInstructionHUD"
        rootEntity.position = rootPosition

        headAnchor.addChild(rootEntity)
        root = rootEntity
        makeInert(rootEntity)

        print(
            """
            [PlagueHUD] head-tracked instruction HUD created
              position: \(rootPosition)
              font: \(font.fontName)
            """
        )
    }

    func show(
        _ text: String,
        on headAnchor: AnchorEntity
    ) {
        ensure(on: headAnchor)

        guard text != lastText else {
            return
        }

        lastText = text

        textEntity?.removeFromParent()
        backgroundEntity?.removeFromParent()

        guard let root,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            textEntity = nil
            backgroundEntity = nil
            return
        }

        let wrapped = wrapHUDText(text)

        let mesh = MeshResource.generateText(
            wrapped,
            extrusionDepth: 0.0005,
            font: font,
            containerFrame: CGRect(
                x: -420,
                y: -70,
                width: 840,
                height: 140
            ),
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

        var textMaterial = UnlitMaterial()
        textMaterial.color = .init(
            tint: UIColor(
                red: 0.92,
                green: 0.86,
                blue: 0.72,
                alpha: 1.0
            )
        )
        textMaterial.blending = .transparent(opacity: 1.0)

        let label = ModelEntity(
            mesh: mesh,
            materials: [textMaterial]
        )

        let bounds = mesh.bounds
        let centeredTextPosition = SIMD3<Float>(
            -bounds.center.x * textScale,
            -bounds.center.y * textScale,
            0
        )

        label.name = "PlagueInstructionHUDText"
        label.scale = SIMD3<Float>(repeating: textScale)
        label.position = centeredTextPosition

        let width = max(
            0.52,
            bounds.extents.x * textScale + horizontalPadding
        )

        let height = max(
            0.095,
            bounds.extents.y * textScale + verticalPadding
        )

        var backgroundMaterial = UnlitMaterial()
        backgroundMaterial.color = .init(
            tint: UIColor(
                red: 0.01,
                green: 0.008,
                blue: 0.006,
                alpha: 0.74
            )
        )
        backgroundMaterial.blending = .transparent(opacity: 1.0)

        let background = ModelEntity(
            mesh: .generatePlane(
                width: width,
                height: height
            ),
            materials: [backgroundMaterial]
        )
        background.name = "PlagueInstructionHUDBackground"
        background.position = SIMD3<Float>(0, 0, -0.012)

        root.addChild(background)
        root.addChild(label)

        textEntity = label
        backgroundEntity = background

        makeInert(root)

        print(
            """
            [PlagueHUD] instruction text updated
              text: \(wrapped)
              width: \(width)
              height: \(height)
              textBoundsCenter: \(bounds.center)
              centeredTextPosition: \(centeredTextPosition)
            """
        )
    }

    func clear() {
        textEntity?.removeFromParent()
        backgroundEntity?.removeFromParent()

        textEntity = nil
        backgroundEntity = nil
        lastText = ""

        print("[PlagueHUD] instruction HUD cleared")
    }

    private func wrapHUDText(
        _ text: String
    ) -> String {
        guard text.count > 48 else {
            return text
        }

        let words = text.split(separator: " ")
        var line1: [Substring] = []
        var line2: [Substring] = []

        for word in words {
            let current = line1.joined(separator: " ")
            if current.count < 42 {
                line1.append(word)
            } else {
                line2.append(word)
            }
        }

        return [
            line1.joined(separator: " "),
            line2.joined(separator: " ")
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func makeInert(
        _ entity: Entity
    ) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)

        for child in entity.children {
            makeInert(child)
        }
    }
}
