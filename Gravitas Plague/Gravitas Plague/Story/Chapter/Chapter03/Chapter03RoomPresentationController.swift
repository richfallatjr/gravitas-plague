import Foundation
import RealityKit

struct Chapter03RoomSuppressionReceipt: Equatable {
    let transitionID: UUID
    let enabledStateByRootID: [String: Bool]
    let layoutFingerprintBefore: TuringStoryEstablishedLayoutFingerprint
    let adjustmentReceipt: TuringStoryAdjustmentSuspensionReceipt
    let fullBlackConfirmed: Bool
}

@MainActor
final class Chapter03RoomPresentationController {
    private let roots: [String: Entity]
    private let adjustments: TuringStoryPlacementAdjustmentCoordinator
    private let surfaces: Chapter03SurfaceSequenceCoordinator
    private let fingerprintProvider: () throws -> TuringStoryEstablishedLayoutFingerprint
    private weak var blackout: ImmersiveBlackoutController?

    init(
        roots: [String: Entity],
        adjustments: TuringStoryPlacementAdjustmentCoordinator,
        surfaces: Chapter03SurfaceSequenceCoordinator,
        fingerprintProvider: @escaping () throws -> TuringStoryEstablishedLayoutFingerprint
    ) {
        self.roots = roots
        self.adjustments = adjustments
        self.surfaces = surfaces
        self.fingerprintProvider = fingerprintProvider
    }

    func bind(blackout: ImmersiveBlackoutController) {
        self.blackout = blackout
    }

    func suppressUnderFullBlack(
        transitionID: UUID
    ) throws -> Chapter03RoomSuppressionReceipt {
        guard let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }
        try blackout.requireFullBlackOwnership(requestID: transitionID)
        let before = try fingerprintProvider()
        let states = roots.mapValues(\.isEnabled)
        surfaces.closeAll(reason: "chapter03.mike.fullBlack")
        let adjustmentReceipt = adjustments.suspendPresentationForCinematic(
            reason: "chapter03.mike.fullBlack"
        )
        for root in roots.values {
            root.isEnabled = false
        }
        guard roots.values.allSatisfy({ !$0.isEnabled }),
              try fingerprintProvider() == before else {
            throw Chapter03Error.layoutChangedDuringStart
        }
        return Chapter03RoomSuppressionReceipt(
            transitionID: transitionID,
            enabledStateByRootID: states,
            layoutFingerprintBefore: before,
            adjustmentReceipt: adjustmentReceipt,
            fullBlackConfirmed: abs(blackout.blackoutOpacity - 1) <= 0.0001
        )
    }

    func restoreUnderFullBlack(
        _ receipt: Chapter03RoomSuppressionReceipt,
        reason: String
    ) throws {
        guard let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }
        try blackout.requireFullBlackOwnership(requestID: receipt.transitionID)
        for (id, enabled) in receipt.enabledStateByRootID {
            roots[id]?.isEnabled = enabled
        }
        adjustments.restorePresentationAfterCinematic(
            receipt.adjustmentReceipt,
            reason: reason
        )
        guard try fingerprintProvider() == receipt.layoutFingerprintBefore else {
            throw Chapter03Error.layoutChangedDuringStart
        }
    }
}
