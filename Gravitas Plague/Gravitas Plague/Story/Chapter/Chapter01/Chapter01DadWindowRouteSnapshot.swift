import Foundation
import simd

struct Chapter01DadWindowRouteSnapshot: Sendable {
    let windowWorldTransform: simd_float4x4

    let entryWorldPosition: SIMD3<Float>
    let centerWorldPosition: SIMD3<Float>
    let exitWorldPosition: SIMD3<Float>

    let entryWalkWorldForward: SIMD3<Float>
    let centerFacingWindowWorldForward: SIMD3<Float>
    let exitWalkWorldForward: SIMD3<Float>

    let entryWalkWorldOrientation: simd_quatf
    let centerFacingWindowWorldOrientation: simd_quatf
    let exitWalkWorldOrientation: simd_quatf

    let entryToCenterSignedTurnRadians: Float
    let centerToExitSignedTurnRadians: Float
}

enum Chapter01DadWindowRouteBuilder {
    private static let directionToleranceRadians =
        5 * Float.pi / 180
    private static let minimumSegmentDistanceMeters: Float = 0.05

    static func make(
        windowWorldTransform: simd_float4x4,
        entryWorldPosition: SIMD3<Float>,
        centerWorldPosition: SIMD3<Float>,
        exitWorldPosition: SIMD3<Float>,
        portalNormalCandidateWorld: SIMD3<Float>
    ) throws -> Chapter01DadWindowRouteSnapshot {
        try requireFinite(windowWorldTransform, label: "windowWorldTransform")
        try requireFinite(entryWorldPosition, label: "entryWorldPosition")
        try requireFinite(centerWorldPosition, label: "centerWorldPosition")
        try requireFinite(exitWorldPosition, label: "exitWorldPosition")

        let entryDelta = centerWorldPosition - entryWorldPosition
        let exitDelta = exitWorldPosition - centerWorldPosition
        let entryDistance = simd_length(
            SIMD3<Float>(entryDelta.x, 0, entryDelta.z)
        )
        let exitDistance = simd_length(
            SIMD3<Float>(exitDelta.x, 0, exitDelta.z)
        )
        guard entryDistance > minimumSegmentDistanceMeters,
              exitDistance > minimumSegmentDistanceMeters else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad window route contains a segment shorter than 0.05 meters."
            )
        }

        let entryForward = try PortalLocalHeadingResolver
            .normalizedHorizontal(
                entryDelta,
                label: "Dad entry-to-center"
            )
        let exitForward = try PortalLocalHeadingResolver
            .normalizedHorizontal(
                exitDelta,
                label: "Dad center-to-exit"
            )
        let travelAgreement = max(
            -1,
            min(1, simd_dot(entryForward, exitForward))
        )
        guard acos(travelAgreement) <= directionToleranceRadians else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad entry and exit routes do not share the authored travel heading."
            )
        }

        let candidateA = try PortalLocalHeadingResolver
            .normalizedHorizontal(
                portalNormalCandidateWorld,
                label: "Dad portal normal A"
            )
        let candidateB = -candidateA

        let selected: (
            forward: SIMD3<Float>,
            leftTurn: Float,
            rightTurn: Float
        )
        if let candidate = try validatedCandidate(
            candidateA,
            entryForward: entryForward,
            exitForward: exitForward
        ) {
            selected = candidate
        } else if let candidate = try validatedCandidate(
            candidateB,
            entryForward: entryForward,
            exitForward: exitForward
        ) {
            selected = candidate
        } else {
            throw Chapter01Error.openingResourceUnavailable(
                "Neither window-plane normal satisfies Dad's authored left-turn/right-turn route."
            )
        }

        let entryOrientation = try PortalLocalHeadingResolver.worldYaw(
            forward: entryForward,
            label: "Dad entry orientation"
        )
        let centerOrientation = try PortalLocalHeadingResolver.worldYaw(
            forward: selected.forward,
            label: "Dad center orientation"
        )
        let exitOrientation = try PortalLocalHeadingResolver.worldYaw(
            forward: exitForward,
            label: "Dad exit orientation"
        )

        try requireFinite(entryOrientation, label: "entryWorldOrientation")
        try requireFinite(centerOrientation, label: "centerWorldOrientation")
        try requireFinite(exitOrientation, label: "exitWorldOrientation")

        return Chapter01DadWindowRouteSnapshot(
            windowWorldTransform: windowWorldTransform,
            entryWorldPosition: entryWorldPosition,
            centerWorldPosition: centerWorldPosition,
            exitWorldPosition: exitWorldPosition,
            entryWalkWorldForward: entryForward,
            centerFacingWindowWorldForward: selected.forward,
            exitWalkWorldForward: exitForward,
            entryWalkWorldOrientation: entryOrientation,
            centerFacingWindowWorldOrientation: centerOrientation,
            exitWalkWorldOrientation: exitOrientation,
            entryToCenterSignedTurnRadians: selected.leftTurn,
            centerToExitSignedTurnRadians: selected.rightTurn
        )
    }

    private static func validatedCandidate(
        _ candidate: SIMD3<Float>,
        entryForward: SIMD3<Float>,
        exitForward: SIMD3<Float>
    ) throws -> (
        forward: SIMD3<Float>,
        leftTurn: Float,
        rightTurn: Float
    )? {
        let leftTurn = try PortalLocalHeadingResolver.signedYawRadians(
            from: entryForward,
            to: candidate
        )
        let rightTurn = try PortalLocalHeadingResolver.signedYawRadians(
            from: candidate,
            to: exitForward
        )
        guard abs(leftTurn - Float.pi / 2) <= directionToleranceRadians,
              abs(rightTurn + Float.pi / 2) <= directionToleranceRadians else {
            return nil
        }
        return (candidate, leftTurn, rightTurn)
    }

    private static func requireFinite(
        _ value: SIMD3<Float>,
        label: String
    ) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad route value \(label) is not finite."
            )
        }
    }

    private static func requireFinite(
        _ value: simd_quatf,
        label: String
    ) throws {
        let vector = value.vector
        guard vector.x.isFinite,
              vector.y.isFinite,
              vector.z.isFinite,
              vector.w.isFinite,
              abs(simd_length(vector) - 1) <= 0.001 else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad route value \(label) is not a normalized finite quaternion."
            )
        }
    }

    private static func requireFinite(
        _ value: simd_float4x4,
        label: String
    ) throws {
        for column in [
            value.columns.0,
            value.columns.1,
            value.columns.2,
            value.columns.3
        ] where !column.x.isFinite ||
            !column.y.isFinite ||
            !column.z.isFinite ||
            !column.w.isFinite {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad route value \(label) is not finite."
            )
        }
    }
}
