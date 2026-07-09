import Foundation
import simd

struct TuringStoryDoorBundlePlacement: Codable, Equatable, Sendable {
    var wallID: UUID
    var localX: Float
    var localY: Float
    var depthOffset: Float
    var width: Float
    var height: Float
    var floorWorldY: Float?
    var worldYawRadians: Float
}

enum TuringStoryDoorBundleTuning {
    static let assetImportScale: Float = 1.0
    static let preferredCenterHeightMeters: Float = 1.05
    static let minBottomClearanceMeters: Float = 0.02
    static let wallMarginMeters: Float = 0.10
    static let depthOffset: Float = 0.018
    static let defaultWidthMeters: Float = 0.95
    static let defaultHeightMeters: Float = 2.05
    static let occupancyPaddingMeters: Float = 0.14
    static let posterAvoidanceWeight: Float = 8.0
    static let portalAvoidanceWeight: Float = 8.0
    static let walkieAvoidanceWeight: Float = 5.0
    static let windowAvoidanceWeight: Float = 5.0
}

func turingDoorWallRect(
    for placement: TuringStoryDoorBundlePlacement
) -> WallLocalRect {
    WallLocalRect(
        minX: placement.localX - placement.width * 0.5,
        minY: placement.localY - placement.height * 0.5,
        maxX: placement.localX + placement.width * 0.5,
        maxY: placement.localY + placement.height * 0.5
    )
}
