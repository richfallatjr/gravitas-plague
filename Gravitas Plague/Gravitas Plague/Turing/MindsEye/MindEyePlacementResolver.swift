import Foundation
import simd

nonisolated enum MindEyePlacementResolver {
    static func resolve(
        geometry: MindEyePlacementGeometry,
        tuning: MindEyePlacementTuning
    ) -> Result<MindEyeResolvedPlacement, MindEyeFailure> {
        guard validates(tuning) else {
            return .failure(failure("Mind's Eye placement tuning is nonfinite or invalid."))
        }

        let usableBounds = geometry.centeringBounds.flatMap { $0.isUsable ? $0 : nil }
        let center = usableBounds?.center ?? geometry.fallbackCenter
        guard MindEyeFiniteVector.validates(center) else {
            return .failure(failure("Mind's Eye placement has no finite center."))
        }

        var resolved = SIMD3<Float>(
            center.x,
            center.y + tuning.verticalLiftMeters,
            center.z + tuning.forwardOffsetMeters
        )
        var verticalClampApplied = false
        var forwardClampApplied = false

        if let obstruction = geometry.obstructionBounds,
           obstruction.isFinite,
           obstruction.isOrdered {
            let minimumY = obstruction.max.y +
                tuning.shelfClearanceMeters +
                tuning.cardHeightMeters * 0.5
            if resolved.y < minimumY {
                resolved.y = minimumY
                verticalClampApplied = true
            }
            let minimumZ = obstruction.max.z + tuning.shelfClearanceMeters
            if resolved.z < minimumZ {
                resolved.z = minimumZ
                forwardClampApplied = true
            }
        }

        guard MindEyeFiniteVector.validates(resolved) else {
            return .failure(failure("Mind's Eye placement resolved to nonfinite coordinates."))
        }

        return .success(
            MindEyeResolvedPlacement(
                providerID: geometry.providerID,
                providerRevision: geometry.revision,
                localPosition: resolved,
                usedFallbackCenter: usableBounds == nil,
                verticalClampApplied: verticalClampApplied,
                forwardClampApplied: forwardClampApplied
            )
        )
    }

    private static func validates(_ tuning: MindEyePlacementTuning) -> Bool {
        [
            tuning.cardWidthMeters,
            tuning.cardHeightMeters,
            tuning.verticalLiftMeters,
            tuning.forwardOffsetMeters,
            tuning.shelfClearanceMeters
        ].allSatisfy(\.isFinite) &&
            tuning.cardWidthMeters > 0 &&
            tuning.cardHeightMeters > 0 &&
            tuning.shelfClearanceMeters >= 0
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .placementInvalid,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
