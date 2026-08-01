import Foundation
import simd

struct TuringStoryWindowBundlePlacement: Codable, Equatable, Sendable {
    var wallID: UUID
    var localX: Float
    var localY: Float
    var depthOffset: Float
    var width: Float
    var height: Float
    var floorWorldY: Float?
    var worldYawRadians: Float
}

enum TuringStoryWindowBundleTuning {
    static let assetImportScale: Float = 3.0
    static let feetToMeters: Float = 0.3048
    static let preferredBottomHeightMeters: Float = 2.8 * feetToMeters
    static let chapter01DadRouteSideOffsetMeters: Float = 4.0
    static let chapter01DadRouteDepthMeters: Float = 1.0
    static let minBottomClearanceMeters: Float = 0.30
    static let wallMarginMeters: Float = 0.12
    static let depthOffset: Float = 0.018
    static let defaultWidthMeters: Float = 0.88
    static let defaultHeightMeters: Float = 0.72
    static let occupancyPaddingMeters: Float = 0.12
    static let posterAvoidanceWeight: Float = 6.0
    static let portalAvoidanceWeight: Float = 6.0
    static let walkieAvoidanceWeight: Float = 4.0
}

func turingWindowWallRect(
    for placement: TuringStoryWindowBundlePlacement
) -> WallLocalRect {
    WallLocalRect(
        minX: placement.localX - placement.width * 0.5,
        minY: placement.localY - placement.height * 0.5,
        maxX: placement.localX + placement.width * 0.5,
        maxY: placement.localY + placement.height * 0.5
    )
}
