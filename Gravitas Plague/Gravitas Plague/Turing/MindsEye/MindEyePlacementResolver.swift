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
        let resolvedCenter: SIMD3<Float>
        let usedFallbackCenter: Bool
        if let icon = geometry.iconRelativePlacement {
            guard validates(icon) else {
                return .failure(failure("Mind's Eye icon-relative placement is nonfinite or invalid."))
            }
            // A prop's bounds may own horizontal composition while the shared
            // action icon continues to own bottom-edge height and viewing depth.
            // Providers without centering bounds retain the original icon X.
            let horizontalCenterX = usableBounds?.center.x ??
                icon.iconTopCenter.x
            resolvedCenter = SIMD3<Float>(
                horizontalCenterX,
                icon.iconTopCenter.y +
                    icon.bottomEdgeClearanceMeters +
                    tuning.cardHeightMeters * 0.5,
                icon.iconTopCenter.z + icon.forwardOffsetMeters
            )
            usedFallbackCenter = false
        } else {
            let center = usableBounds?.center ?? geometry.fallbackCenter
            guard MindEyeFiniteVector.validates(center) else {
                return .failure(failure("Mind's Eye placement has no finite center."))
            }
            resolvedCenter = SIMD3<Float>(
                center.x,
                center.y + tuning.verticalLiftMeters,
                center.z + tuning.forwardOffsetMeters
            )
            usedFallbackCenter = usableBounds == nil
        }

        var resolved = resolvedCenter
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
                usedFallbackCenter: usedFallbackCenter,
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

    private static func validates(
        _ placement: MindEyeIconRelativePlacement
    ) -> Bool {
        MindEyeFiniteVector.validates(placement.iconTopCenter) &&
            placement.bottomEdgeClearanceMeters.isFinite &&
            placement.bottomEdgeClearanceMeters >= 0 &&
            placement.forwardOffsetMeters.isFinite &&
            placement.forwardOffsetMeters >= 0
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
