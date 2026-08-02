import Foundation
import RealityKit
import UIKit
import simd

@MainActor
final class StoryTitleCardWorldPresenter {
    private weak var worldAnchor: AnchorEntity?
    private var currentCard: Entity?
    private var currentRequestID: UUID?

    func bind(worldAnchor: AnchorEntity) {
        self.worldAnchor = worldAnchor
    }

    func show(
        requestID: UUID,
        descriptor: StoryTitleCardDescriptor,
        originFromDevice: simd_float4x4
    ) throws {
        guard let worldAnchor else {
            throw StoryTitleCardError.missingPresentationOwner
        }

        removeAll(reason: "replacement")
        let card = StoryTitleCardTextFactory.makeCard(descriptor)
        card.isEnabled = false
        worldAnchor.addChild(card)
        card.setTransformMatrix(
            CinematicWorldCardTransform.worldTransform(
                originFromDevice: originFromDevice
            ),
            relativeTo: nil
        )
        card.isEnabled = true
        currentCard = card
        currentRequestID = requestID

        print(
            """
            [StoryTitleCard] procedural card shown
              requestID: \(requestID.uuidString)
              cardID: \(descriptor.id.rawValue)
              title: \(descriptor.title)
              subtitle: \(descriptor.subtitle ?? "none")
              titleFont: \(PlagueHUDTypography.title().fontName)
              subtitleFont: \(PlagueHUDTypography.subtitle().fontName)
              distanceFromHeadset: \(CinematicWorldCardTransform.distanceMeters)
              verticalLiftMeters: \(CinematicWorldCardTransform.worldYLiftMeters)
              xTiltDegrees: \(CinematicWorldCardTransform.xTiltDegrees)
              followsHeadset: false
            """
        )
    }

    func remove(requestID: UUID) {
        guard currentRequestID == requestID else { return }
        currentCard?.removeFromParent()
        currentCard = nil
        currentRequestID = nil
    }

    func removeAll(reason: String) {
        guard currentCard != nil || currentRequestID != nil else { return }
        currentCard?.removeFromParent()
        currentCard = nil
        currentRequestID = nil
        print("[StoryTitleCard] world card removed reason=\(reason)")
    }
}
